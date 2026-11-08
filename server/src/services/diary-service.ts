/**
 * 日记与块序列的核心业务逻辑。
 *
 * 合并规则（需求 4.2）：
 *   1. 版本向量支配 → 取新的
 *   2. 并发 → 两版都保留，按 (HLC 物理时间, 逻辑计数, 设备号) 全序选出规范版本
 *   3. 落败的一方写入 block_versions，保留 30 天，用户可在版本历史里找回
 *   4. 每一次写入都往 changes 表追加一条，客户端靠游标增量拉取
 *
 * 服务端只比较元数据（版本向量、HLC），不解密块内容 —— 这是密文外壳的前提。
 */
import { pool, withTransaction } from '../db/pool.ts';
import { compareVv, mergeVv, normalize, type VersionVector } from '../domain/vv.ts';
import { compareHlc, decodeHlc, type Hlc } from '../domain/hlc.ts';
import { writability } from '../domain/calendar.ts';
import { AppError } from '../http/errors.ts';
import { appendReplicationLog, type BlockLogPayload, type DiaryLogPayload } from './replication.ts';

export type BlockType = 'text' | 'image' | 'audio' | 'video' | 'divider';
export type EncMode = 'none' | 'aes-256-gcm';

export interface BlockInput {
  blockId: string;
  blockType: BlockType;
  orderKey: string;
  vv: VersionVector;
  hlc: string;
  payload: Buffer;
  mediaRef?: string | null;
  enc?: EncMode;
  nonce?: Buffer | null;
  keyId?: string | null;
}

export interface StoredBlock {
  blockId: string;
  blockType: BlockType;
  orderKey: string;
  vv: VersionVector;
  hlc: string;
  enc: EncMode;
  nonce: string | null;
  keyId: string | null;
  mediaRef: string | null;
  payload: string;
  tombstone: boolean;
  updatedAt: string;
}

export interface ConflictInfo {
  blockId: string;
  winnerHlc: string;
  loserHlc: string;
  archivedVersionId: string;
}

export interface DiarySummary {
  diaryId: string;
  diaryDate: string;
  vv: VersionVector;
  timeSuspect: boolean;
  blockCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface ApplyBatchInput {
  diaryDate: string;
  tzId: string;
  /** 客户端自报的当前时间，用于检测时钟偏差 */
  clientNow: string;
  deviceId: string | null;
  operations: BlockInput[];
}

export interface ApplyBatchResult {
  diaryId: string;
  diaryDate: string;
  today: string;
  serverNow: string;
  timeSuspect: boolean;
  blocks: StoredBlock[];
  conflicts: ConflictInfo[];
  cursor: number;
}

interface BlockRow {
  id: string;
  diary_id: string;
  block_type: BlockType;
  order_key: string;
  vv: VersionVector;
  hlc: string;
  hlc_phys: string | number;
  hlc_counter: number;
  hlc_device: string;
  enc: EncMode;
  nonce: Buffer | null;
  key_id: string | null;
  media_ref: string | null;
  payload: Buffer;
  tombstone: boolean;
  created_at: Date;
  updated_at: Date;
}

function mapBlock(row: BlockRow): StoredBlock {
  return {
    blockId: row.id,
    blockType: row.block_type,
    orderKey: row.order_key,
    vv: normalize(row.vv),
    hlc: row.hlc,
    enc: row.enc,
    nonce: row.nonce ? row.nonce.toString('base64') : null,
    keyId: row.key_id,
    mediaRef: row.media_ref,
    payload: row.payload.toString('base64'),
    tombstone: row.tombstone,
    updatedAt: row.updated_at.toISOString(),
  };
}

function toBlockLogPayload(row: BlockRow, diaryDate: string, tzId: string): BlockLogPayload {
  return {
    blockId: row.id,
    diaryId: row.diary_id,
    diaryDate,
    tzId,
    blockType: row.block_type,
    orderKey: row.order_key,
    vv: normalize(row.vv),
    hlc: row.hlc,
    hlcPhys: Number(row.hlc_phys),
    hlcCounter: row.hlc_counter,
    hlcDevice: row.hlc_device,
    enc: row.enc,
    nonce: row.nonce ? row.nonce.toString('base64') : null,
    keyId: row.key_id,
    payload: row.payload.toString('base64'),
    mediaRef: row.media_ref,
    tombstone: row.tombstone,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

async function appendChange(
  client: { query: (text: string, values?: unknown[]) => Promise<{ rows: Array<{ seq?: string }> }> },
  userId: string,
  entity: 'diary' | 'block',
  entityId: string,
  op: 'upsert' | 'delete',
  hlc: string,
): Promise<number> {
  const { rows } = await client.query(
    `INSERT INTO changes (user_id, entity, entity_id, op, hlc)
     VALUES ($1, $2, $3, $4, $5) RETURNING seq`,
    [userId, entity, entityId, op, hlc],
  );
  return Number(rows[0]?.seq ?? 0);
}

async function ensureDiary(
  client: { query: (text: string, values?: unknown[]) => Promise<{ rows: Array<{ id: string; vv: VersionVector; time_suspect: boolean }> }> },
  userId: string,
  diaryDate: string,
  tzId: string,
): Promise<{ id: string; vv: VersionVector; timeSuspect: boolean }> {
  const inserted = await client.query(
    `INSERT INTO diaries (user_id, diary_date, tz_id)
     VALUES ($1, $2, $3)
     ON CONFLICT (user_id, diary_date) DO NOTHING
     RETURNING id, vv, time_suspect`,
    [userId, diaryDate, tzId],
  );
  const row = inserted.rows[0];
  if (row) return { id: row.id, vv: normalize(row.vv), timeSuspect: row.time_suspect };

  const existing = await client.query(
    'SELECT id, vv, time_suspect FROM diaries WHERE user_id = $1 AND diary_date = $2',
    [userId, diaryDate],
  );
  const found = existing.rows[0];
  if (!found) throw AppError.internal('日记创建失败');
  return { id: found.id, vv: normalize(found.vv), timeSuspect: found.time_suspect };
}

async function archiveVersion(
  client: { query: (text: string, values?: unknown[]) => Promise<{ rows: Array<{ id: string }> }> },
  blockId: string,
  row: { vv: VersionVector; hlc: string; enc: EncMode; nonce: Buffer | null; key_id: string | null; payload: Buffer },
  deviceId: string | null,
): Promise<string> {
  const hlc = decodeHlc(row.hlc);
  const { rows } = await client.query(
    `INSERT INTO block_versions (block_id, vv, hlc, hlc_phys, hlc_counter, hlc_device, enc, nonce, key_id, payload, device_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
     RETURNING id`,
    [
      blockId,
      JSON.stringify(row.vv),
      row.hlc,
      hlc.phys,
      hlc.counter,
      hlc.device,
      row.enc,
      row.nonce,
      row.key_id,
      row.payload,
      deviceId,
    ],
  );
  return rows[0]?.id ?? '';
}

/**
 * 批量应用块变更。整个批次在一个事务里，要么全成要么全不成。
 */
export async function applyBatch(
  userId: string,
  dayCutHour: number,
  writeWindowDays: number,
  input: ApplyBatchInput,
  serverNow: Date,
): Promise<ApplyBatchResult> {
  const verdict = writability(input.diaryDate, serverNow, input.tzId, {
    cutHour: dayCutHour,
    windowDays: writeWindowDays,
  });
  if (!verdict.writable) {
    throw AppError.dateWindow(verdict.reason ?? 'past-window', input.diaryDate, verdict.today);
  }

  const clientNow = new Date(input.clientNow);
  const timeSuspect =
    Number.isFinite(clientNow.getTime()) &&
    Math.abs(serverNow.getTime() - clientNow.getTime()) > 300_000;

  return withTransaction(async (client) => {
    const diary = await ensureDiary(client, userId, input.diaryDate, input.tzId);
    if (timeSuspect && !diary.timeSuspect) {
      await client.query('UPDATE diaries SET time_suspect = true WHERE id = $1', [diary.id]);
    }

    let cursor = 0;
    const conflicts: ConflictInfo[] = [];
    let diaryVv = diary.vv;
    const changedBlocks = new Set<string>();

    for (const op of input.operations) {
      const incomingHlc = decodeHlc(op.hlc);
      const existing = await client.query<BlockRow>(
        'SELECT * FROM blocks WHERE id = $1 AND diary_id = $2 FOR UPDATE',
        [op.blockId, diary.id],
      );
      const current = existing.rows[0];

      if (!current) {
        await client.query(
          `INSERT INTO blocks (id, diary_id, block_type, order_key, vv, hlc, hlc_phys, hlc_counter, hlc_device,
                               enc, nonce, key_id, payload, media_ref)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
          [
            op.blockId,
            diary.id,
            op.blockType,
            op.orderKey,
            JSON.stringify(op.vv),
            op.hlc,
            incomingHlc.phys,
            incomingHlc.counter,
            incomingHlc.device,
            op.enc ?? 'none',
            op.nonce ?? null,
            op.keyId ?? null,
            op.payload,
            op.mediaRef ?? null,
          ],
        );
        cursor = Math.max(
          cursor,
          await appendChange(client, userId, 'block', op.blockId, 'upsert', op.hlc),
        );
        changedBlocks.add(op.blockId);
        diaryVv = mergeVv(diaryVv, op.vv);
        continue;
      }

      const relation = compareVv(op.vv, normalize(current.vv));
      if (relation === 'equal' || relation === 'b-dominates') {
        // 已有版本更新或相同，忽略这次提交（不覆盖、不报错）
        continue;
      }

      const currentHlc = decodeHlc(current.hlc);
      const incomingWins = relation === 'a-dominates' || compareHlc(incomingHlc, currentHlc) > 0;

      if (relation === 'concurrent') {
        // 并发：落败的一方进历史，并记一条冲突让客户端提示用户
        const loser = incomingWins
          ? {
              vv: normalize(current.vv),
              hlc: current.hlc,
              enc: current.enc,
              nonce: current.nonce,
              key_id: current.key_id,
              payload: current.payload,
            }
          : {
              vv: op.vv,
              hlc: op.hlc,
              enc: op.enc ?? 'none',
              nonce: op.nonce ?? null,
              key_id: op.keyId ?? null,
              payload: op.payload,
            };
        const archivedId = await archiveVersion(client, op.blockId, loser, input.deviceId);

        const unresolved = await client.query(
          `SELECT id FROM conflicts WHERE block_id = $1 AND resolved_at IS NULL LIMIT 1`,
          [op.blockId],
        );
        if (unresolved.rows.length === 0) {
          await client.query(
            `INSERT INTO conflicts (user_id, diary_id, block_id, winner_id, loser_id)
             VALUES ($1, $2, $3, $4, $5)`,
            [userId, diary.id, op.blockId, null, archivedId],
          );
        }
        conflicts.push({
          blockId: op.blockId,
          winnerHlc: incomingWins ? op.hlc : current.hlc,
          loserHlc: incomingWins ? current.hlc : op.hlc,
          archivedVersionId: archivedId,
        });
        if (!incomingWins) {
          diaryVv = mergeVv(diaryVv, op.vv);
          continue;
        }
      } else {
        // 直接因果覆盖：旧版本仍归档，便于版本历史回看
        await archiveVersion(
          client,
          op.blockId,
          {
            vv: normalize(current.vv),
            hlc: current.hlc,
            enc: current.enc,
            nonce: current.nonce,
            key_id: current.key_id,
            payload: current.payload,
          },
          input.deviceId,
        );
      }

      await client.query(
        `UPDATE blocks
            SET block_type = $2, order_key = $3, vv = $4, hlc = $5, hlc_phys = $6, hlc_counter = $7,
                hlc_device = $8, enc = $9, nonce = $10, key_id = $11, payload = $12, media_ref = $13,
                tombstone = false, tombstoned_at = NULL, updated_at = now()
          WHERE id = $1`,
        [
          op.blockId,
          op.blockType,
          op.orderKey,
          JSON.stringify(op.vv),
          op.hlc,
          incomingHlc.phys,
          incomingHlc.counter,
          incomingHlc.device,
          op.enc ?? 'none',
          op.nonce ?? null,
          op.keyId ?? null,
          op.payload,
          op.mediaRef ?? null,
        ],
      );
      cursor = Math.max(cursor, await appendChange(client, userId, 'block', op.blockId, 'upsert', op.hlc));
      changedBlocks.add(op.blockId);
      diaryVv = mergeVv(diaryVv, op.vv);
    }

    await client.query('UPDATE diaries SET vv = $2, updated_at = now() WHERE id = $1', [
      diary.id,
      JSON.stringify(diaryVv),
    ]);

    const blocks = await client.query<BlockRow>(
      'SELECT * FROM blocks WHERE diary_id = $1 ORDER BY order_key ASC',
      [diary.id],
    );

    // 写入复制日志：副本靠它追平（同一事务内，保证不会出现"数据在但日志丢"）
    const diaryLog: DiaryLogPayload = {
      diaryId: diary.id,
      diaryDate: input.diaryDate,
      tzId: input.tzId,
      vv: diaryVv,
      timeSuspect: timeSuspect || diary.timeSuspect,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    await appendReplicationLog(
      {
        userId,
        entity: 'diary',
        entityId: diary.id,
        op: 'upsert',
        hlc: input.operations[0]?.hlc ?? '',
        payload: diaryLog,
      },
      client,
    );
    for (const row of blocks.rows) {
      if (!changedBlocks.has(row.id)) continue;
      await appendReplicationLog(
        {
          userId,
          entity: 'block',
          entityId: row.id,
          op: row.tombstone ? 'delete' : 'upsert',
          hlc: row.hlc,
          payload: toBlockLogPayload(row, input.diaryDate, input.tzId),
        },
        client,
      );
    }

    return {
      diaryId: diary.id,
      diaryDate: input.diaryDate,
      today: verdict.today,
      serverNow: serverNow.toISOString(),
      timeSuspect,
      blocks: blocks.rows.map(mapBlock),
      conflicts,
      cursor,
    };
  });
}

export async function listDiaries(
  userId: string,
  fromIso: string,
  toIso: string,
): Promise<DiarySummary[]> {
  const { rows } = await pool.query<{
    id: string;
    diary_date: string;
    vv: VersionVector;
    time_suspect: boolean;
    created_at: Date;
    updated_at: Date;
    block_count: number;
  }>(
    `SELECT d.id, d.diary_date, d.vv, d.time_suspect, d.created_at, d.updated_at,
            COALESCE(c.n, 0)::int AS block_count
       FROM diaries d
       LEFT JOIN (
         SELECT diary_id, count(*) AS n FROM blocks WHERE tombstone = false GROUP BY diary_id
       ) c ON c.diary_id = d.id
      WHERE d.user_id = $1 AND d.diary_date BETWEEN $2 AND $3
      ORDER BY d.diary_date ASC`,
    [userId, fromIso, toIso],
  );
  return rows.map((r) => ({
    diaryId: r.id,
    diaryDate: toIsoDate(r.diary_date),
    vv: normalize(r.vv),
    timeSuspect: r.time_suspect,
    blockCount: r.block_count,
    createdAt: r.created_at.toISOString(),
    updatedAt: r.updated_at.toISOString(),
  }));
}

export async function getDiary(
  userId: string,
  diaryDate: string,
): Promise<{ diary: DiarySummary; blocks: StoredBlock[] } | null> {
  const { rows } = await pool.query<{
    id: string;
    diary_date: string;
    vv: VersionVector;
    time_suspect: boolean;
    created_at: Date;
    updated_at: Date;
  }>('SELECT * FROM diaries WHERE user_id = $1 AND diary_date = $2', [userId, diaryDate]);
  const diary = rows[0];
  if (!diary) return null;

  const blocks = await pool.query<BlockRow>(
    'SELECT * FROM blocks WHERE diary_id = $1 AND tombstone = false ORDER BY order_key ASC',
    [diary.id],
  );
  return {
    diary: {
      diaryId: diary.id,
      diaryDate: toIsoDate(diary.diary_date),
      vv: normalize(diary.vv),
      timeSuspect: diary.time_suspect,
      blockCount: blocks.rows.length,
      createdAt: diary.created_at.toISOString(),
      updatedAt: diary.updated_at.toISOString(),
    },
    blocks: blocks.rows.map(mapBlock),
  };
}

export async function tombstoneBlock(
  userId: string,
  diaryDate: string,
  blockId: string,
  vv: VersionVector,
  hlc: string,
): Promise<{ ok: true; cursor: number }> {
  const parsed = decodeHlc(hlc);
  return withTransaction(async (client) => {
    const diary = await client.query<{ id: string }>(
      'SELECT id FROM diaries WHERE user_id = $1 AND diary_date = $2',
      [userId, diaryDate],
    );
    const diaryId = diary.rows[0]?.id;
    if (!diaryId) throw AppError.notFound('日记不存在');

    const result = await client.query(
      `UPDATE blocks
          SET tombstone = true, tombstoned_at = now(), vv = $3, hlc = $4,
              hlc_phys = $5, hlc_counter = $6, hlc_device = $7, updated_at = now()
        WHERE id = $1 AND diary_id = $2`,
      [blockId, diaryId, JSON.stringify(vv), hlc, parsed.phys, parsed.counter, parsed.device],
    );
    if (result.rowCount === 0) throw AppError.notFound('块不存在');
    const cursor = await appendChange(client, userId, 'block', blockId, 'delete', hlc);

    // 墓碑同样要进复制日志，否则副本会把"已删除"当成"从未见过"
    const { rows: blockRows } = await client.query<BlockRow>('SELECT * FROM blocks WHERE id = $1', [blockId]);
    const row = blockRows[0];
    if (row) {
      const { rows: diaryRows } = await client.query<{ tz_id: string }>('SELECT tz_id FROM diaries WHERE id = $1', [
        diaryId,
      ]);
      await appendReplicationLog(
        {
          userId,
          entity: 'block',
          entityId: blockId,
          op: 'delete',
          hlc,
          payload: toBlockLogPayload(row, diaryDate, diaryRows[0]?.tz_id ?? 'UTC'),
        },
        client,
      );
    }
    return { ok: true as const, cursor };
  });
}

/** 版本历史：被覆盖/冲突落败的旧版本 */
export async function listBlockVersions(
  userId: string,
  blockId: string,
): Promise<
  Array<{ versionId: string; hlc: string; vv: VersionVector; payload: string; createdAt: string }>
> {
  const { rows } = await pool.query<{
    id: string;
    hlc: string;
    vv: VersionVector;
    payload: Buffer;
    created_at: Date;
  }>(
    `SELECT v.id, v.hlc, v.vv, v.payload, v.created_at
       FROM block_versions v
       JOIN blocks b ON b.id = v.block_id
       JOIN diaries d ON d.id = b.diary_id
      WHERE d.user_id = $1 AND v.block_id = $2
      ORDER BY v.hlc_phys DESC, v.hlc_counter DESC`,
    [userId, blockId],
  );
  return rows.map((r) => ({
    versionId: r.id,
    hlc: r.hlc,
    vv: normalize(r.vv),
    payload: r.payload.toString('base64'),
    createdAt: r.created_at.toISOString(),
  }));
}

export function toIsoDate(value: Date | string): string {
  // date 列由 pg 的 1082 解析器原样返回字符串；这里兼容 Date 以防其他调用点
  if (typeof value === 'string') return value.slice(0, 10);
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, '0')}-${String(value.getDate()).padStart(2, '0')}`;
}

export type { Hlc };
