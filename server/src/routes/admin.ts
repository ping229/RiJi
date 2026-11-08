/**
 * 管理员接口。全部要求 role = admin。
 *
 * 这些接口不返回任何日记正文、媒体字节或块载荷 —— 只有数量、状态和时间。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireAdmin, currentUserId } from '../http/auth-guard.ts';
import { AppError } from '../http/errors.ts';
import { listAudit } from '../services/audit.ts';
import {
  addNode,
  clusterStats,
  consistencySummary,
  createUser,
  deleteUser,
  finalizeRetire,
  listNodes,
  listUsers,
  promoteNode,
  requestFullSync,
  setUserQuota,
  retireNode,
  setNodeStatus,
  setUserStatus,
} from '../services/admin-service.ts';

const createUserSchema = z.object({
  // 配额以 GB 为单位，0 表示不限制；不填则用服务器默认值
  quotaGb: z.number().min(0).max(10240).optional(),
  username: z.string().min(2).max(64),
  password: z.string().min(8).max(256),
  role: z.enum(['user', 'admin']).default('user'),
});

const deleteUserSchema = z.object({ confirmUsername: z.string().min(1) });

const addNodeSchema = z.object({
  id: z.string().min(2).max(64),
  endpoint: z.string().url(),
  role: z.enum(['primary', 'replica']).default('replica'),
});

export async function registerAdminRoutes(app: FastifyInstance): Promise<void> {
  const guard = { preHandler: requireAdmin };

  app.get('/api/admin/stats', guard, async () => clusterStats());

  app.get('/api/admin/users', guard, async (req) => {
    const q = z
      .object({ query: z.string().default(''), status: z.string().default('') })
      .parse(req.query);
    return { users: await listUsers(q.query, q.status) };
  });

  app.post('/api/admin/users', guard, async (req, reply) => {
    const body = createUserSchema.parse(req.body);
    const actor = currentUserId(req);
    // quotaGb 不传时用服务器默认值；传 0 表示不限制
    const quotaBytes = body.quotaGb === undefined
      ? undefined
      : (body.quotaGb <= 0 ? null : Math.round(body.quotaGb * 1024 * 1024 * 1024));
    const created = await createUser(actor, body.username, body.password, body.role, quotaBytes);
    return reply.code(201).send(created);
  });

  /** 调整存储配额：quotaGb = 0 表示不限制 */
  app.patch('/api/admin/users/:id/quota', guard, async (req) => {
    const { id } = req.params as { id: string };
    const body = z.object({ quotaGb: z.number().min(0).max(10240) }).parse(req.body);
    const quotaBytes = body.quotaGb <= 0 ? null : Math.round(body.quotaGb * 1024 * 1024 * 1024);
    await setUserQuota(currentUserId(req), id, quotaBytes);
    return { ok: true, quotaGb: body.quotaGb };
  });
  app.post('/api/admin/users/:id/disable', guard, async (req) => {
    const { id } = req.params as { id: string };
    await setUserStatus(currentUserId(req), id, 'disabled');
    return { ok: true };
  });

  app.post('/api/admin/users/:id/enable', guard, async (req) => {
    const { id } = req.params as { id: string };
    await setUserStatus(currentUserId(req), id, 'active');
    return { ok: true };
  });

  app.delete('/api/admin/users/:id', guard, async (req) => {
    const { id } = req.params as { id: string };
    const body = deleteUserSchema.parse(req.body ?? {});
    await deleteUser(currentUserId(req), id, body.confirmUsername);
    return { ok: true };
  });

  app.get('/api/admin/nodes', guard, async () => ({ nodes: await listNodes() }));

  app.post('/api/admin/nodes', guard, async (req, reply) => {
    const body = addNodeSchema.parse(req.body);
    const node = await addNode(currentUserId(req), body.id, body.endpoint, body.role);
    return reply.code(201).send(node);
  });

  app.post('/api/admin/nodes/:id/disable', guard, async (req) => {
    await setNodeStatus(currentUserId(req), (req.params as { id: string }).id, 'disable');
    return { ok: true };
  });

  app.post('/api/admin/nodes/:id/enable', guard, async (req) => {
    await setNodeStatus(currentUserId(req), (req.params as { id: string }).id, 'enable');
    return { ok: true };
  });

  app.post('/api/admin/nodes/:id/online', guard, async (req) => {
    await setNodeStatus(currentUserId(req), (req.params as { id: string }).id, 'online');
    return { ok: true };
  });

  app.post('/api/admin/nodes/:id/promote', guard, async (req) => {
    await promoteNode(currentUserId(req), (req.params as { id: string }).id);
    return { ok: true };
  });

  app.post('/api/admin/nodes/:id/full-sync', guard, async (req) => {
    await requestFullSync(currentUserId(req), (req.params as { id: string }).id);
    return { ok: true };
  });

  app.post('/api/admin/nodes/:id/retire', guard, async (req) => {
    const result = await retireNode(currentUserId(req), (req.params as { id: string }).id);
    return result;
  });

  app.post('/api/admin/nodes/:id/retire/finalize', guard, async (req) => {
    await finalizeRetire(currentUserId(req), (req.params as { id: string }).id);
    return { ok: true };
  });

  app.get('/api/admin/audit', guard, async (req) => {
    const q = z.object({ limit: z.coerce.number().int().min(1).max(500).default(100) }).parse(req.query);
    return { entries: await listAudit(q.limit) };
  });

  app.post('/api/admin/consistency', guard, async () => {
    const summary = await consistencySummary();
    return { ok: true, summary };
  });

  // 明确不提供：导出用户日记、查看日记内容。任何管理员请求到这里都会被 404。
  app.all('/api/admin/users/:id/diaries', guard, async () => {
    throw AppError.forbidden('管理员无权访问任何用户的日记内容');
  });
}
