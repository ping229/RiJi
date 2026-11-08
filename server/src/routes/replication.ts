/**
 * 节点间复制接口。只对持有复制令牌的节点开放。
 * 生产环境应替换为 mTLS（需求 10.4），这里先用共享令牌保证可用性与可测性。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { config } from '../config.ts';
import { pool } from '../db/pool.ts';
import { AppError } from '../http/errors.ts';
import { getCursor, headSeq, readLogSince, setCursor, toUserLogPayload, type UserRowForReplication } from '../services/replication.ts';
import { promises as fs } from 'node:fs';
import path from 'node:path';

function assertToken(req: { headers: Record<string, unknown>; protocol?: string }): void {
  // 启用 mTLS 后，复制接口只在 9443 的证书通道上开放；
  // 明文端口上的同路径请求一律拒绝，避免绕过证书校验。
  if (config.replicationTlsDir && req.protocol !== 'https') {
    throw AppError.forbidden('复制接口只接受 mTLS 连接');
  }
  const token = req.headers['x-replication-token'];
  if (typeof token !== 'string' || token !== config.replicationToken) {
    throw AppError.forbidden('复制令牌无效');
  }
}

export async function registerReplicationRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/replication/log', async (req, reply) => {
    assertToken(req);
    const q = z
      .object({
        since: z.coerce.number().int().nonnegative().default(0),
        limit: z.coerce.number().int().min(1).max(500).default(200),
      })
      .parse(req.query);

    const entries = await readLogSince(q.since, q.limit);
    const head = await headSeq();
    reply.header('cache-control', 'no-store');
    return { entries, head };
  });

  /**
   * 全量基线快照：新节点加入时先拉一遍存量数据（需求 7.2.1）。
   * 分页返回，避免一次性把整个库塞进内存。
   */
  app.get('/api/replication/snapshot', async (req) => {
    assertToken(req);
    const q = z
      .object({
        kind: z.enum(['user', 'diary', 'block', 'version']),
        offset: z.coerce.number().int().nonnegative().default(0),
        limit: z.coerce.number().int().min(1).max(500).default(200),
      })
      .parse(req.query);

    if (q.kind === 'user') {
      const { rows } = await pool.query<UserRowForReplication>(
        'SELECT * FROM users ORDER BY id LIMIT $1 OFFSET $2',
        [q.limit + 1, q.offset],
      );
      const hasMore = rows.length > q.limit;
      const page = rows.slice(0, q.limit);
      return {
        kind: 'user',
        items: page.map((r) => ({
          userId: r.id,
          payload: toUserLogPayload(r),
        })),
        nextOffset: hasMore ? q.offset + q.limit : null,
      };
    }

    if (q.kind === 'version') {
      const { rows } = await pool.query(
        `SELECT v.*, b.diary_id, d.user_id
           FROM block_versions v
           JOIN blocks b ON b.id = v.block_id
           JOIN diaries d ON d.id = b.diary_id
          ORDER BY v.id LIMIT $1 OFFSET $2`,
        [q.limit + 1, q.offset],
      );
      const hasMore = rows.length > q.limit;
      const page = rows.slice(0, q.limit);
      return {
        kind: 'version',
        items: page.map((r) => ({
          userId: r.user_id,
          payload: {
            versionId: r.id,
            blockId: r.block_id,
            vv: r.vv,
            hlc: r.hlc,
            hlcPhys: Number(r.hlc_phys),
            hlcCounter: r.hlc_counter,
            hlcDevice: r.hlc_device,
            enc: r.enc,
            nonce: r.nonce ? r.nonce.toString('base64') : null,
            keyId: r.key_id,
            payload: r.payload.toString('base64'),
            deviceId: r.device_id,
            createdAt: new Date(r.created_at).toISOString(),
          },
        })),
        nextOffset: hasMore ? q.offset + q.limit : null,
      };
    }

    if (q.kind === 'diary') {
      const { rows } = await pool.query(
        `SELECT d.id, d.user_id, d.diary_date, d.tz_id, d.vv, d.time_suspect, d.created_at, d.updated_at
           FROM diaries d ORDER BY d.id LIMIT $1 OFFSET $2`,
        [q.limit + 1, q.offset],
      );
      const hasMore = rows.length > q.limit;
      const page = rows.slice(0, q.limit);
      return {
        kind: 'diary',
        items: page.map((r) => ({
          userId: r.user_id,
          payload: {
            diaryId: r.id,
            diaryDate: r.diary_date,
            tzId: r.tz_id,
            vv: r.vv,
            timeSuspect: r.time_suspect,
            createdAt: new Date(r.created_at).toISOString(),
            updatedAt: new Date(r.updated_at).toISOString(),
          },
        })),
        nextOffset: hasMore ? q.offset + q.limit : null,
      };
    }

    const { rows } = await pool.query(
      `SELECT b.*, d.user_id, d.diary_date, d.tz_id
         FROM blocks b JOIN diaries d ON d.id = b.diary_id
        ORDER BY b.id LIMIT $1 OFFSET $2`,
      [q.limit + 1, q.offset],
    );
    const hasMore = rows.length > q.limit;
    const page = rows.slice(0, q.limit);
    return {
      kind: 'block',
      items: page.map((r) => ({
        userId: r.user_id,
        payload: {
          blockId: r.id,
          diaryId: r.diary_id,
          diaryDate: r.diary_date,
          tzId: r.tz_id,
          blockType: r.block_type,
          orderKey: r.order_key,
          vv: r.vv,
          hlc: r.hlc,
          hlcPhys: Number(r.hlc_phys),
          hlcCounter: r.hlc_counter,
          hlcDevice: r.hlc_device,
          enc: r.enc,
          nonce: r.nonce ? r.nonce.toString('base64') : null,
          keyId: r.key_id,
          payload: r.payload.toString('base64'),
          mediaRef: r.media_ref,
          tombstone: r.tombstone,
          createdAt: new Date(r.created_at).toISOString(),
          updatedAt: new Date(r.updated_at).toISOString(),
        },
      })),
      nextOffset: hasMore ? q.offset + q.limit : null,
    };
  });

  app.get('/api/replication/media/:key', async (req, reply) => {
    assertToken(req);
    const { key } = req.params as { key: string };
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.query);

    const { rows } = await pool.query<{ blob_path: string; mime: string | null; enc: string; nonce: Buffer | null }>(
      'SELECT blob_path, mime, enc, nonce FROM media WHERE user_id = $1 AND media_key = $2',
      [userId, key],
    );
    const row = rows[0];
    if (!row) throw AppError.notFound('媒体不存在');

    const body = await fs.readFile(path.resolve(row.blob_path)).catch(() => null);
    if (!body) throw AppError.notFound('媒体文件缺失');

    reply
      .header('content-type', row.mime ?? 'application/octet-stream')
      .header('x-media-mime', row.mime ?? 'application/octet-stream')
      .header('x-media-enc', row.enc);
    if (row.nonce) reply.header('x-media-nonce', row.nonce.toString('base64'));
    return reply.send(body);
  });

  /**
   * 只取媒体元数据（不含文件字节）。
   * 副本用它修补历史遗留的"加密媒体 but nonce 为空"的行，不必重下几百 MB。
   */
  app.get('/api/replication/media/:key/meta', async (req) => {
    assertToken(req);
    const { key } = req.params as { key: string };
    const { userId } = z.object({ userId: z.string().uuid() }).parse(req.query);
    const { rows } = await pool.query<{ mime: string | null; enc: string; nonce: Buffer | null; byte_size: string }>(
      'SELECT mime, enc, nonce, byte_size FROM media WHERE user_id = $1 AND media_key = $2',
      [userId, key],
    );
    const row = rows[0];
    if (!row) throw AppError.notFound('媒体不存在');
    return {
      mediaKey: key,
      mime: row.mime,
      enc: row.enc,
      nonce: row.nonce ? row.nonce.toString('base64') : null,
      byteSize: Number(row.byte_size),
    };
  });

  app.post('/api/replication/heartbeat', async (req) => {
    assertToken(req);
    const body = z
      .object({
        nodeId: z.string().min(1),
        cursor: z.number().int().nonnegative(),
        fullSyncStarted: z.boolean().optional(),
      })
      .parse(req.body ?? {});

    const head = await headSeq();

    // 副本回报"我已开始全量同步"，清掉请求标记
    if (body.fullSyncStarted) {
      await pool.query(
        'UPDATE nodes SET full_sync_started_at = now(), full_sync_requested_at = NULL WHERE id = $1',
        [body.nodeId],
      );
    }
    await pool.query(
      `INSERT INTO nodes (id, role, status, last_heartbeat_at, replication_cursor, replication_lag)
       VALUES ($1, 'replica', 'syncing', now(), $2, $3)
       ON CONFLICT (id) DO UPDATE
         SET last_heartbeat_at = now(),
             replication_cursor = EXCLUDED.replication_cursor,
             replication_lag = EXCLUDED.replication_lag,
             status = CASE WHEN nodes.status IN ('retired', 'disabled') THEN nodes.status ELSE 'online' END`,
      [body.nodeId, body.cursor, Math.max(0, head - body.cursor)],
    );

    // 告诉副本是否需要做一次全量同步
    const { rows } = await pool.query<{ pending: boolean }>(
      'SELECT (full_sync_requested_at IS NOT NULL) AS pending FROM nodes WHERE id = $1',
      [body.nodeId],
    );
    return { ok: true, head, fullSync: rows[0]?.pending ?? false };
  });

  app.post('/api/replication/promote', async (req) => {
    assertToken(req);
    const body = z.object({ nodeId: z.string().min(1) }).parse(req.body ?? {});
    // 被提升的节点接管主节点身份，之后不再从原主节点拉取
    await pool.query("UPDATE nodes SET role = 'primary' WHERE id = $1", [body.nodeId]);
    return { ok: true };
  });

  app.get('/api/replication/status', async (req) => {
    assertToken(req);
    const cursor = await getCursor(config.nodeId);
    const localHead = await headSeq();
    // 副本的本地日志是空的，head 应以游标为准，避免出现 cursor > head 的误导性输出
    const head = config.nodeRole === 'replica' ? Math.max(cursor, localHead) : localHead;
    return {
      nodeId: config.nodeId,
      role: config.nodeRole,
      cursor,
      head,
      lag: config.nodeRole === 'replica' ? 0 : Math.max(0, head - cursor),
      primaryUrl: config.primaryUrl || null,
    };
  });

  app.post('/api/replication/cursor', async (req) => {
    assertToken(req);
    const body = z.object({ nodeId: z.string().min(1), cursor: z.number().int().nonnegative() }).parse(req.body ?? {});
    await setCursor(body.nodeId, body.cursor);
    return { ok: true };
  });
}
