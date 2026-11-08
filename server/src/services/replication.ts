/**
 * 复制服务：主节点写日志，副本按游标拉取并幂等应用。
 *
 * 关键约束（对应需求 4.5 / 10.1）：
 *   * 每个节点有独立的数据库，不共享任何存储
 *   * 写入只提交主节点，主节点本地持久化后即返回成功（不阻塞用户）
 *   * 副本异步追平，通过游标与心跳暴露"落后多少"
 *   * 媒体按需回源，避免整库搬运
 */
import { pool } from '../db/pool.ts';
import { config } from '../config.ts';
import { replicationRequest } from './replication-http.ts';
import { compareVv, normalize, type VersionVector } from '../domain/vv.ts';
import { compareHlc, decodeHlc } from '../domain/hlc.ts';

/** 块的历史版本（冲突落败/被覆盖）。随块一起复制，副本上也能看版本历史 */
export interface ArchivedVersionPayload {
  versionId: string;
  blockId: string;
  vv: Record<string, number>;
  hlc: string;
  hlcPhys: number;
  hlcCounter: number;
  hlcDevice: string;
  enc: string;
  nonce: string | null;
  keyId: string | null;
  payload: string;
  deviceId: string | null;
  createdAt: string;
}

export interface BlockLogPayload {
  blockId: string;
  diaryId: string;
  diaryDate: string;
  tzId: string;
  blockType: string;
  orderKey: string;
  vv: Record<string, number>;
  hlc: string;
  hlcPhys: number;
  hlcCounter: number;
  hlcDevice: string;
  enc: string;
  nonce: string | null;
  keyId: string | null;
  payload: string;
  mediaRef: string | null;
  tombstone: boolean;
  createdAt: string;
  updatedAt: string;
  /** 该块的全部历史版本；老日志没有这个字段，按空处理 */
  archivedVersions?: ArchivedVersionPayload[];
}

export interface DiaryLogPayload {
  diaryId: string;
  diaryDate: string;
  tzId: string;
  vv: Record<string, number>;
  timeSuspect: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface UserLogPayload {
  id: string;
  username: string;
  role: string;
  status: string;
  passwordHash: string;
  passwordSalt: string;
  tzId: string;
  dayCutHour: number;
  createdAt: string;
  disabledAt: string | null;
  /**
   * 端到端加密相关字段：必须随用户一起复制。
   * 少了这组字段，副本上的账号登录时拿不到盐与包裹体，
   * 客户端会误以为是"首次启用加密"，从而生成新密钥并覆盖包裹体——
   * 那会把老数据变成永久解不开。现场事故就是这么发生的，别再删。
   */
  kdfSalt: string | null;
  kdfIterations: number;
  keyWrap: string | null;
  keyWrapNonce: string | null;
  keyWrapVersion: number;
  recoveryWrap: string | null;
  recoveryNonce: string | null;
  recoveryCreatedAt: string | null;
  recoveryProof: string | null;
  /** bigint 用字符串传，避免 JS number 精度丢失 */
  quotaBytes: string | null;
}

export type LogPayload = BlockLogPayload | DiaryLogPayload | UserLogPayload | ArchivedVersionPayload;

/** users 表里参与复制的列（DB 行原样，snake_case） */
export interface UserRowForReplication {
  id: string;
  username: string;
  role: string;
  status: string;
  password_hash: string;
  password_salt: string;
  tz_id: string;
  day_cut_hour: number;
  created_at: Date | string;
  disabled_at: Date | string | null;
  kdf_salt: string | null;
  kdf_iterations: number | null;
  key_wrap: string | null;
  key_wrap_nonce: string | null;
  key_wrap_version: number | null;
  recovery_wrap: string | null;
  recovery_nonce: string | null;
  recovery_created_at: Date | string | null;
  recovery_proof: string | null;
  quota_bytes: string | number | null;
}

function iso(value: Date | string | null | undefined): string {
  if (!value) return new Date(0).toISOString();
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function isoOrNull(value: Date | string | null | undefined): string | null {
  return value ? iso(value) : null;
}

/** 把 users 行转成复制载荷。所有调用点共用，避免又漏字段 */
export function toUserLogPayload(row: UserRowForReplication): UserLogPayload {
  return {
    id: row.id,
    username: row.username,
    role: row.role,
    status: row.status,
    passwordHash: row.password_hash,
    passwordSalt: row.password_salt,
    tzId: row.tz_id,
    dayCutHour: row.day_cut_hour,
    createdAt: iso(row.created_at),
    disabledAt: isoOrNull(row.disabled_at),
    kdfSalt: row.kdf_salt ?? null,
    kdfIterations: row.kdf_iterations ?? 210_000,
    keyWrap: row.key_wrap ?? null,
    keyWrapNonce: row.key_wrap_nonce ?? null,
    keyWrapVersion: row.key_wrap_version ?? 1,
    recoveryWrap: row.recovery_wrap ?? null,
    recoveryNonce: row.recovery_nonce ?? null,
    recoveryCreatedAt: isoOrNull(row.recovery_created_at),
    recoveryProof: row.recovery_proof ?? null,
    quotaBytes: row.quota_bytes === null || row.quota_bytes === undefined ? null : String(row.quota_bytes),
  };
}

/** 主节点：把一次变更写入复制日志 */
export async function appendReplicationLog(
  entry: {
    userId: string;
    entity: 'user' | 'diary' | 'block';
    entityId: string;
    op: 'upsert' | 'delete';
    hlc: string;
    payload: LogPayload;
  },
  client: { query: (text: string, values?: unknown[]) => Promise<unknown> } = pool,
): Promise<void> {
  await client.query(
    `INSERT INTO replication_log (user_id, entity, entity_id, op, hlc, payload)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [entry.userId, entry.entity, entry.entityId, entry.op, entry.hlc, JSON.stringify(entry.payload)],
  );
}

export async function readLogSince(since: number, limit: number): Promise<
  Array<{
    seq: number;
    userId: string;
    entity: 'user' | 'diary' | 'block';
    entityId: string;
    op: 'upsert' | 'delete';
    hlc: string;
    payload: LogPayload;
  }>
> {
  const { rows } = await pool.query(
    `SELECT seq, user_id, entity, entity_id, op, hlc, payload
       FROM replication_log WHERE seq > $1 ORDER BY seq ASC LIMIT $2`,
    [since, limit],
  );
  return rows.map((r) => ({
    seq: Number(r.seq),
    userId: r.user_id,
    entity: r.entity,
    entityId: r.entity_id,
    op: r.op,
    hlc: r.hlc,
    payload: r.payload,
  }));
}

export async function headSeq(): Promise<number> {
  const { rows } = await pool.query<{ seq: string | null }>('SELECT MAX(seq)::text AS seq FROM replication_log');
  return Number(rows[0]?.seq ?? 0);
}

export async function getCursor(nodeId: string): Promise<number> {
  const { rows } = await pool.query<{ cursor: string }>(
    'SELECT cursor::text AS cursor FROM replication_state WHERE node_id = $1',
    [nodeId],
  );
  return Number(rows[0]?.cursor ?? 0);
}

export async function setCursor(nodeId: string, cursor: number): Promise<void> {
  await pool.query(
    `INSERT INTO replication_state (node_id, cursor, updated_at) VALUES ($1, $2, now())
     ON CONFLICT (node_id) DO UPDATE SET cursor = EXCLUDED.cursor, updated_at = now()`,
    [nodeId, cursor],
  );
}

/** 副本：应用一条变更（幂等，重复应用结果一致） */
export async function applyEntry(entry: {
  seq: number;
  userId: string;
  entity: 'user' | 'diary' | 'block' | 'version';
  entityId: string;
  op: 'upsert' | 'delete';
  hlc: string;
  payload: LogPayload;
}): Promise<void> {
  if (entry.entity === 'version') {
    const v = entry.payload as ArchivedVersionPayload;
    await applyArchivedVersions(v.blockId, [v]);
    return;
  }

  if (entry.entity === 'user') {
    const p = entry.payload as UserLogPayload;
    if (entry.op === 'delete') {
      await pool.query('DELETE FROM users WHERE id = $1', [p.id]);
      return;
    }
    await pool.query(
      // 同名但不同 id 的历史账号先改名，避免复制时撞唯一约束导致整批失败
      `UPDATE users SET username = username || '#local-' || substr(id::text, 1, 8)
        WHERE username = $2 AND id <> $1`,
      [p.id, p.username],
    );
    await pool.query(
      `INSERT INTO users (id, username, role, status, password_hash, password_salt, tz_id, day_cut_hour,
                          created_at, disabled_at, kdf_salt, kdf_iterations, key_wrap, key_wrap_nonce,
                          key_wrap_version, recovery_wrap, recovery_nonce, recovery_created_at, recovery_proof,
                          quota_bytes)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9::timestamptz, now()), $10::timestamptz,
               $11, $12, $13, $14, $15, $16, $17, $18, $19, $20)
       ON CONFLICT (id) DO UPDATE
         SET username = EXCLUDED.username,
             role = EXCLUDED.role,
             status = EXCLUDED.status,
             password_hash = EXCLUDED.password_hash,
             password_salt = EXCLUDED.password_salt,
             tz_id = EXCLUDED.tz_id,
             day_cut_hour = EXCLUDED.day_cut_hour,
             disabled_at = EXCLUDED.disabled_at,
             -- 加密材料只向上覆盖：本地已有、主节点为空的字段不能被抹掉
             kdf_salt = COALESCE(EXCLUDED.kdf_salt, users.kdf_salt),
             kdf_iterations = EXCLUDED.kdf_iterations,
             key_wrap = COALESCE(EXCLUDED.key_wrap, users.key_wrap),
             key_wrap_nonce = COALESCE(EXCLUDED.key_wrap_nonce, users.key_wrap_nonce),
             key_wrap_version = EXCLUDED.key_wrap_version,
             recovery_wrap = COALESCE(EXCLUDED.recovery_wrap, users.recovery_wrap),
             recovery_nonce = COALESCE(EXCLUDED.recovery_nonce, users.recovery_nonce),
             recovery_created_at = COALESCE(EXCLUDED.recovery_created_at, users.recovery_created_at),
             recovery_proof = COALESCE(EXCLUDED.recovery_proof, users.recovery_proof),
             quota_bytes = EXCLUDED.quota_bytes`,
      [
        p.id,
        p.username,
        p.role,
        p.status,
        p.passwordHash,
        p.passwordSalt,
        p.tzId,
        p.dayCutHour,
        p.createdAt,
        p.disabledAt,
        p.kdfSalt ?? null,
        p.kdfIterations ?? 210_000,
        p.keyWrap ?? null,
        p.keyWrapNonce ?? null,
        p.keyWrapVersion ?? 1,
        p.recoveryWrap ?? null,
        p.recoveryNonce ?? null,
        p.recoveryCreatedAt ?? null,
        p.recoveryProof ?? null,
        p.quotaBytes ?? null,
      ],
    );
    return;
  }

  if (entry.entity === 'diary') {
    const p = entry.payload as DiaryLogPayload;
    await ensureReplicaUser(entry.userId);
    await pool.query(
      `INSERT INTO diaries (id, user_id, diary_date, tz_id, vv, time_suspect, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7::timestamptz, now()), COALESCE($8::timestamptz, now()))
       ON CONFLICT (user_id, diary_date) DO UPDATE
         SET vv = EXCLUDED.vv, time_suspect = EXCLUDED.time_suspect, updated_at = now()`,
      [p.diaryId, entry.userId, p.diaryDate, p.tzId, JSON.stringify(p.vv), p.timeSuspect, p.createdAt, p.updatedAt],
    );
    return;
  }

  const p = entry.payload as BlockLogPayload;

  // 用户可能还没同步过来（或历史上被手工建库漏了日志）：先补占位，
  // 否则外键会让这一条永远失败，副本游标卡死再也追不上。
  await ensureReplicaUser(entry.userId);

  await pool.query(
    `INSERT INTO diaries (id, user_id, diary_date, tz_id)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (user_id, diary_date) DO NOTHING`,
    [p.diaryId, entry.userId, p.diaryDate, p.tzId],
  );
  const { rows: diaryRows } = await pool.query<{ id: string }>(
    'SELECT id FROM diaries WHERE user_id = $1 AND diary_date = $2',
    [entry.userId, p.diaryDate],
  );
  const diaryId = diaryRows[0]?.id ?? p.diaryId;

  if (!(await shouldApplyBlock(p))) return;

  await pool.query(
    `INSERT INTO blocks (id, diary_id, block_type, order_key, vv, hlc, hlc_phys, hlc_counter, hlc_device,
                         enc, nonce, key_id, payload, media_ref, tombstone, tombstoned_at, created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15,
             CASE WHEN $15 THEN now() ELSE NULL END,
             COALESCE($16::timestamptz, now()), COALESCE($17::timestamptz, now()))
     ON CONFLICT (id) DO UPDATE
       SET block_type = EXCLUDED.block_type,
           order_key = EXCLUDED.order_key,
           vv = EXCLUDED.vv,
           hlc = EXCLUDED.hlc,
           hlc_phys = EXCLUDED.hlc_phys,
           hlc_counter = EXCLUDED.hlc_counter,
           hlc_device = EXCLUDED.hlc_device,
           enc = EXCLUDED.enc,
           nonce = EXCLUDED.nonce,
           key_id = EXCLUDED.key_id,
           payload = EXCLUDED.payload,
           media_ref = EXCLUDED.media_ref,
           tombstone = EXCLUDED.tombstone,
           tombstoned_at = CASE WHEN EXCLUDED.tombstone THEN now() ELSE NULL END,
           updated_at = now()`,
    [
      p.blockId,
      diaryId,
      p.blockType,
      p.orderKey,
      JSON.stringify(p.vv),
      p.hlc,
      p.hlcPhys,
      p.hlcCounter,
      p.hlcDevice,
      p.enc,
      p.nonce ? Buffer.from(p.nonce, 'base64') : null,
      p.keyId,
      Buffer.from(p.payload, 'base64'),
      p.mediaRef,
      p.tombstone,
      p.createdAt,
      p.updatedAt,
    ],
  );

  await applyArchivedVersions(p.blockId, p.archivedVersions);
}

/**
 * 副本该不该接受这条块变更。
 *
 * 必须和主节点的仲裁规则一致（diary-service.applyBatch）：
 * 版本向量支配才覆盖；并发时 HLC 大的胜。之前这里只看 HLC，
 * 会出现"主节点按因果保留旧内容、副本却按时间覆盖成新内容"的漂移。
 */
async function shouldApplyBlock(p: BlockLogPayload): Promise<boolean> {
  const { rows } = await pool.query<{ vv: VersionVector; hlc: string }>(
    'SELECT vv, hlc FROM blocks WHERE id = $1',
    [p.blockId],
  );
  const current = rows[0];
  if (!current) return true;

  const relation = compareVv(p.vv ?? {}, normalize(current.vv));
  if (relation === 'equal' || relation === 'b-dominates') return false;
  if (relation === 'a-dominates') return true;

  // 并发：与主节点一致，HLC 较大者胜；HLC 不可解析时退回字符串比较
  try {
    return compareHlc(decodeHlc(p.hlc), decodeHlc(current.hlc)) > 0;
  } catch {
    return p.hlc > current.hlc;
  }
}

/**
 * 副本上的用户占位：日记/块有外键指向 users，缺行会让这一条永远应用失败，
 * 游标卡死。占位账号不能登录（随机口令），等真正的 user 日志到了会被覆盖。
 */
async function ensureReplicaUser(userId: string): Promise<void> {
  const { rows } = await pool.query('SELECT 1 FROM users WHERE id = $1', [userId]);
  if (rows.length > 0) return;
  await pool.query(
    `INSERT INTO users (id, username, role, status, password_hash, password_salt)
     VALUES ($1, $2, 'user', 'active', 'placeholder', 'placeholder')
     ON CONFLICT (id) DO NOTHING`,
    [userId, `replicated_${userId.slice(0, 8)}`],
  );
}

/** 历史版本落库（幂等，按主键去重） */
async function applyArchivedVersions(
  blockId: string,
  versions: ArchivedVersionPayload[] | undefined,
): Promise<void> {
  if (!versions || versions.length === 0) return;
  for (const v of versions) {
    await pool.query(
      `INSERT INTO block_versions (id, block_id, vv, hlc, hlc_phys, hlc_counter, hlc_device,
                                   enc, nonce, key_id, payload, device_id, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, COALESCE($13::timestamptz, now()))
       ON CONFLICT (id) DO NOTHING`,
      [
        v.versionId,
        blockId,
        JSON.stringify(v.vv ?? {}),
        v.hlc,
        v.hlcPhys,
        v.hlcCounter,
        v.hlcDevice,
        v.enc,
        v.nonce ? Buffer.from(v.nonce, 'base64') : null,
        v.keyId,
        Buffer.from(v.payload, 'base64'),
        v.deviceId,
        v.createdAt,
      ],
    );
  }
}

/**
 * 副本：从主节点拉取并应用变更，直到追平。
 * 返回本次应用条数与是否还有更多。
 */
export async function pullOnce(): Promise<{ applied: number; head: number; cursor: number; more: boolean }> {
  const primary = config.primaryUrl;
  if (!primary) throw new Error('未配置主节点地址（RJJ_PRIMARY_URL）');

  const cursor = await getCursor(config.nodeId);
  const res = await replicationRequest(`${primary}/api/replication/log?since=${cursor}&limit=200`, {
    timeoutMs: 15_000,
  });
  if (res.status >= 400) {
    throw new Error(`拉取复制日志失败：HTTP ${res.status}`);
  }
  const body = res.json<{
    entries: Array<{
      seq: number;
      userId: string;
      entity: 'user' | 'diary' | 'block';
      entityId: string;
      op: 'upsert' | 'delete';
      hlc: string;
      payload: LogPayload;
    }>;
    head: number;
  }>();

  let applied = 0;
  let lastSeq = cursor;
  for (const entry of body.entries) {
    await applyEntry(entry);
    await fetchMissingMedia(entry, primary);
    lastSeq = entry.seq;
    applied += 1;
  }
  if (lastSeq > cursor) await setCursor(config.nodeId, lastSeq);

  return { applied, head: body.head, cursor: lastSeq, more: lastSeq < body.head };
}

/** 媒体按需回源：块引用了本节点没有的媒体，就从主节点取一次 */
async function fetchMissingMedia(
  entry: { payload: LogPayload; userId: string; entity: string },
  primary: string,
): Promise<void> {
  if (entry.entity !== 'block') return;
  const p = entry.payload as BlockLogPayload;
  if (!p.mediaRef) return;

  const existing = await pool.query('SELECT 1 FROM media WHERE user_id = $1 AND media_key = $2', [
    entry.userId,
    p.mediaRef,
  ]);
  if (existing.rows.length > 0) return;

  const res = await replicationRequest(`${primary}/api/replication/media/${p.mediaRef}?userId=${entry.userId}`, {
    timeoutMs: 120_000,
  });
  if (res.status >= 400) return; // 媒体缺失不阻塞元数据复制，下次应用同一条时重试

  const bytes = res.bytes;
  const mimeHeader = res.headers['x-media-mime'];
  const encHeader = res.headers['x-media-enc'];
  const nonceHeader = res.headers['x-media-nonce'];
  const mime = Array.isArray(mimeHeader) ? mimeHeader[0] : mimeHeader;
  const enc = Array.isArray(encHeader) ? encHeader[0] : encHeader;
  const nonce = Array.isArray(nonceHeader) ? nonceHeader[0] : nonceHeader;
  const path = `${config.mediaDir}/${entry.userId.slice(0, 2)}/${entry.userId}/${p.mediaRef}.bin`;
  const { mkdir, writeFile } = await import('node:fs/promises');
  await mkdir(`${config.mediaDir}/${entry.userId.slice(0, 2)}/${entry.userId}`, { recursive: true });
  await writeFile(path, bytes);
  await pool.query(
    `INSERT INTO media (user_id, media_key, byte_size, mime, enc, nonce, blob_path)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (user_id, media_key) DO UPDATE
       SET nonce = COALESCE(media.nonce, EXCLUDED.nonce),
           mime = COALESCE(EXCLUDED.mime, media.mime),
           byte_size = EXCLUDED.byte_size`,
    [
      entry.userId,
      p.mediaRef,
      bytes.length,
      mime ?? 'application/octet-stream',
      enc ?? p.enc,
      nonce ? Buffer.from(nonce, 'base64') : null,
      path,
    ],
  );
}

/** 副本：向主节点汇报心跳与进度 */
export async function reportHeartbeat(): Promise<void> {
  const primary = config.primaryUrl;
  if (!primary) return;
  const cursor = await getCursor(config.nodeId);
  try {
    const res = await replicationRequest(`${primary}/api/replication/heartbeat`, {
      method: 'POST',
      body: JSON.stringify({ nodeId: config.nodeId, cursor }),
      timeoutMs: 10_000,
    });
    const body = res.json<{ fullSync?: boolean }>();
    if (body.fullSync) {
      // 主节点要求全量同步：把自己的游标清零，下一轮从日志开头重放（幂等）
      await setCursor(config.nodeId, 0);
      await replicationRequest(`${primary}/api/replication/heartbeat`, {
        method: 'POST',
        body: JSON.stringify({ nodeId: config.nodeId, cursor: 0, fullSyncStarted: true }),
        timeoutMs: 10_000,
      });
    }
  } catch {
    // 心跳失败不影响主循环
  }
}

/**
 * 副本：第一次启动时先把主节点的存量数据整份拉过来（全量基线同步）。
 * 只在新节点本地还没有任何日记时执行，避免每次重启都重扫。
 */
export async function bootstrapFromPrimary(): Promise<{ diaries: number; blocks: number }> {
  const primary = config.primaryUrl;
  if (!primary) return { diaries: 0, blocks: 0 };

  const { rows: localRows } = await pool.query<{ n: number }>('SELECT count(*)::int AS n FROM diaries');
  const { rows: stateRows } = await pool.query<{ n: number }>('SELECT count(*)::int AS n FROM replication_state');
  if ((localRows[0]?.n ?? 0) > 0 || (stateRows[0]?.n ?? 0) > 0) {
    return { diaries: 0, blocks: 0 };
  }

  let diaries = 0;
  let blocks = 0;

  for (const kind of ['user', 'diary', 'block', 'version'] as const) {
    let offset = 0;
    for (;;) {
      const res = await replicationRequest(`${primary}/api/replication/snapshot?kind=${kind}&offset=${offset}&limit=200`, {
        timeoutMs: 60_000,
      });
      if (res.status >= 400) throw new Error(`基线同步失败：HTTP ${res.status}`);
      const body = res.json<{
        items: Array<{ userId: string; payload: LogPayload }>;
        nextOffset: number | null;
      }>();

      for (const item of body.items) {
        const payload = item.payload as { diaryId?: string; blockId?: string; id?: string };
        await applyEntry({
          seq: 0,
          userId: item.userId,
          entity: kind,
          entityId: payload.diaryId ?? payload.blockId ?? payload.id ?? '',
          op: 'upsert',
          hlc: '',
          payload: item.payload,
        });
        if (kind === 'diary') diaries += 1;
        else if (kind === 'block') blocks += 1;
      }

      if (body.nextOffset === null) break;
      offset = body.nextOffset;
    }
  }

  // 基线同步完成后，从主节点当前头部开始追增量
  const headRes = await replicationRequest(`${primary}/api/replication/log?since=0&limit=1`, { timeoutMs: 15_000 });
  if (headRes.status < 400) {
    const body = headRes.json<{ head: number }>();
    await setCursor(config.nodeId, body.head);
  }

  return { diaries, blocks };
}

/** 基线同步后补齐媒体：块引用了主节点上有、本地没有的媒体，逐个回源 */
export async function syncMissingMedia(): Promise<number> {
  const primary = config.primaryUrl;
  if (!primary) return 0;

  const { rows } = await pool.query<{ media_ref: string; user_id: string; enc: string }>(
    `SELECT b.media_ref, d.user_id, b.enc
       FROM blocks b
       JOIN diaries d ON d.id = b.diary_id
      WHERE b.media_ref IS NOT NULL AND b.tombstone = false
        AND NOT EXISTS (
          SELECT 1 FROM media m WHERE m.user_id = d.user_id AND m.media_key = b.media_ref
        )`,
  );

  let fetched = 0;
  for (const row of rows) {
    try {
      const res = await fetch(`${primary}/api/replication/media/${row.media_ref}?userId=${row.user_id}`, {
        headers: { 'x-replication-token': config.replicationToken },
        signal: AbortSignal.timeout(120_000),
      });
      if (!res.ok) continue;
      const bytes = Buffer.from(await res.arrayBuffer());
      const dir = `${config.mediaDir}/${row.user_id.slice(0, 2)}/${row.user_id}`;
      const path = `${dir}/${row.media_ref}.bin`;
      const { mkdir, writeFile } = await import('node:fs/promises');
      await mkdir(dir, { recursive: true });
      await writeFile(path, bytes);
      await pool.query(
        `INSERT INTO media (user_id, media_key, byte_size, mime, enc, nonce, blob_path)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (user_id, media_key) DO UPDATE
           SET nonce = COALESCE(media.nonce, EXCLUDED.nonce),
               mime = COALESCE(EXCLUDED.mime, media.mime),
               byte_size = EXCLUDED.byte_size`,
        [
          row.user_id,
          row.media_ref,
          bytes.length,
          res.headers.get('x-media-mime') ?? 'application/octet-stream',
          row.enc,
          res.headers.get('x-media-nonce') ? Buffer.from(res.headers.get('x-media-nonce')!, 'base64') : null,
          path,
        ],
      );
      fetched += 1;
    } catch {
      // 单个媒体失败不影响其他
    }
  }
  return fetched;
}

/**
 * 修数据：早期版本复制媒体时漏了 nonce，副本上加密媒体解不开。
 * 这里只取元数据（不重下文件）把 nonce 补回去，幂等，可重复跑。
 */
export async function repairMediaMetadata(): Promise<number> {
  const primary = config.primaryUrl;
  if (!primary) return 0;

  const { rows } = await pool.query<{ user_id: string; media_key: string }>(
    `SELECT user_id, media_key
       FROM media
      WHERE enc = 'aes-256-gcm' AND nonce IS NULL
      ORDER BY created_at ASC
      LIMIT 500`,
  );

  let repaired = 0;
  for (const row of rows) {
    try {
      const res = await replicationRequest(
        `${primary}/api/replication/media/${row.media_key}/meta?userId=${row.user_id}`,
        { timeoutMs: 15_000 },
      );
      if (res.status >= 400) continue;
      const meta = res.json<{ nonce: string | null; mime: string | null; enc: string }>();
      if (!meta.nonce) continue;
      await pool.query(
        `UPDATE media
            SET nonce = $3,
                mime = COALESCE(mime, $4),
                enc = $5
          WHERE user_id = $1 AND media_key = $2 AND nonce IS NULL`,
        [row.user_id, row.media_key, Buffer.from(meta.nonce, 'base64'), meta.mime, meta.enc],
      );
      repaired += 1;
    } catch {
      // 单个失败不影响其他
    }
  }
  return repaired;
}

/** 副本主循环：持续追平 */
export function startReplicaWorker(log: { info: (msg: string) => void; error: (msg: string) => void }): () => void {
  let stopped = false;
  let timer: NodeJS.Timeout | null = null;

  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      const result = await pullOnce();
      if (result.applied > 0) {
        log.info(`[replica] 应用 ${result.applied} 条变更，游标 ${result.cursor}/${result.head}`);
      }
      await reportHeartbeat();
    } catch (err) {
      log.error(`[replica] 同步失败：${(err as Error).message}`);
    }
    if (!stopped) timer = setTimeout(tick, 1000);
  };

  timer = setTimeout(tick, 500);
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
