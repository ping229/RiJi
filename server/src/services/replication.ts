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
}

export type LogPayload = BlockLogPayload | DiaryLogPayload | UserLogPayload;

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
  entity: 'user' | 'diary' | 'block';
  entityId: string;
  op: 'upsert' | 'delete';
  hlc: string;
  payload: LogPayload;
}): Promise<void> {
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
      `INSERT INTO users (id, username, role, status, password_hash, password_salt, tz_id, day_cut_hour, created_at, disabled_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9::timestamptz, now()), $10::timestamptz)
       ON CONFLICT (id) DO UPDATE
         SET username = EXCLUDED.username,
             role = EXCLUDED.role,
             status = EXCLUDED.status,
             password_hash = EXCLUDED.password_hash,
             password_salt = EXCLUDED.password_salt,
             tz_id = EXCLUDED.tz_id,
             day_cut_hour = EXCLUDED.day_cut_hour,
             disabled_at = EXCLUDED.disabled_at`,
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
      ],
    );
    return;
  }

  if (entry.entity === 'diary') {
    const p = entry.payload as DiaryLogPayload;
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

  // 日记可能还没同步过来，先补一条占位
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
           updated_at = now()
     WHERE blocks.hlc_phys < EXCLUDED.hlc_phys
        OR (blocks.hlc_phys = EXCLUDED.hlc_phys AND blocks.hlc_counter <= EXCLUDED.hlc_counter)`,
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
  const mime = Array.isArray(mimeHeader) ? mimeHeader[0] : mimeHeader;
  const enc = Array.isArray(encHeader) ? encHeader[0] : encHeader;
  const path = `${config.mediaDir}/${entry.userId.slice(0, 2)}/${entry.userId}/${p.mediaRef}.bin`;
  const { mkdir, writeFile } = await import('node:fs/promises');
  await mkdir(`${config.mediaDir}/${entry.userId.slice(0, 2)}/${entry.userId}`, { recursive: true });
  await writeFile(path, bytes);
  await pool.query(
    `INSERT INTO media (user_id, media_key, byte_size, mime, enc, nonce, blob_path)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (user_id, media_key) DO NOTHING`,
    [entry.userId, p.mediaRef, bytes.length, mime ?? 'application/octet-stream', enc ?? p.enc, null, path],
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

  for (const kind of ['user', 'diary', 'block'] as const) {
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
        `INSERT INTO media (user_id, media_key, byte_size, mime, enc, blob_path)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (user_id, media_key) DO NOTHING`,
        [row.user_id, row.media_ref, bytes.length, res.headers.get('x-media-mime') ?? 'application/octet-stream', row.enc, path],
      );
      fetched += 1;
    } catch {
      // 单个媒体失败不影响其他
    }
  }
  return fetched;
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
