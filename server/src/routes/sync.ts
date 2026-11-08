/**
 * 增量同步接口（需求 4.3）。
 * 客户端只带一个游标，服务端返回该游标之后的所有变更 —— 绝不整库重传。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { requireAuth, currentUserId } from '../http/auth-guard.ts';

const querySchema = z.object({
  since: z.coerce.number().int().nonnegative().default(0),
  limit: z.coerce.number().int().min(1).max(1000).default(200),
});

export async function registerSyncRoutes(app: FastifyInstance): Promise<void> {
  app.get('/api/sync/changes', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const q = querySchema.parse(req.query);

    const { rows } = await pool.query<{
      seq: string;
      entity: 'diary' | 'block';
      entity_id: string;
      op: 'upsert' | 'delete';
      hlc: string;
      created_at: Date;
    }>(
      `SELECT seq, entity, entity_id, op, hlc, created_at
         FROM changes
        WHERE user_id = $1 AND seq > $2
        ORDER BY seq ASC
        LIMIT $3`,
      [userId, q.since, q.limit],
    );

    const { rows: maxRows } = await pool.query<{ max: string | null }>(
      'SELECT MAX(seq)::text AS max FROM changes WHERE user_id = $1',
      [userId],
    );

    const changes = rows.map((r) => ({
      seq: Number(r.seq),
      entity: r.entity,
      entityId: r.entity_id,
      op: r.op,
      hlc: r.hlc,
      createdAt: r.created_at.toISOString(),
    }));

    const cursor = changes.length > 0 ? changes[changes.length - 1]!.seq : q.since;
    const head = Number(maxRows[0]?.max ?? 0);

    return {
      changes,
      cursor,
      head,
      hasMore: head > cursor,
      serverNow: new Date().toISOString(),
    };
  });
}
