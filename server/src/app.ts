/**
 * HTTP 应用装配：健康检查、拓扑、认证。后续业务路由都挂在这里。
 */
import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { config } from './config.ts';
import { pool } from './db/pool.ts';
import { AppError } from './http/errors.ts';
import { registerAuthRoutes } from './routes/auth.ts';
import { registerAdminRoutes } from './routes/admin.ts';
import { registerAdminWeb } from './routes/admin-web.ts';
import { registerDiaryRoutes } from './routes/diaries.ts';
import { registerMediaRoutes } from './routes/media.ts';
import { registerRecoveryRoutes } from './routes/recovery.ts';
import { registerReplicationRoutes } from './routes/replication.ts';
import { registerSyncRoutes } from './routes/sync.ts';

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel },
    bodyLimit: config.maxUploadBytes,
    trustProxy: true,
  });

  app.setErrorHandler((err: FastifyError, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.statusCode).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    if (err instanceof ZodError) {
      return reply.status(400).send({
        error: { code: 'VALIDATION_ERROR', message: '请求参数不合法', details: err.issues },
      });
    }
    const fastifyStatus = typeof err.statusCode === 'number' ? err.statusCode : 500;
    if (fastifyStatus >= 400 && fastifyStatus < 500) {
      return reply.status(fastifyStatus).send({
        error: { code: 'CLIENT_ERROR', message: err.message },
      });
    }
    req.log.error({ err }, '未处理的异常');
    return reply.status(500).send({
      error: { code: 'INTERNAL', message: '服务端内部错误' },
    });
  });

  // 媒体上传：把原始流交给路由自己处理，避免把几百 MB 的视频读进内存
  app.addContentTypeParser('application/octet-stream', (_req, payload, done) => {
    done(null, payload);
  });

  // 部署验收要求：/healthz 返回 200（需求 10.8）
  app.get('/healthz', async (_req, reply) => {
    try {
      await pool.query('SELECT 1');
      return { status: 'ok', nodeId: config.nodeId, role: config.nodeRole, time: new Date().toISOString() };
    } catch {
      return reply.status(503).send({ status: 'degraded', nodeId: config.nodeId, reason: 'database-unreachable' });
    }
  });

  // 客户端寻址用：告诉客户端谁是主节点、可读端点有哪些（需求 10.4 补充）
  app.get('/api/topology', async () => {
    const { rows } = await pool.query<{
      id: string;
      role: string;
      status: string;
      endpoint: string | null;
      epoch: number;
      last_heartbeat_at: Date | null;
    }>('SELECT id, role, status, endpoint, epoch, last_heartbeat_at FROM nodes ORDER BY id');

    const primary = rows.find((r) => r.role === 'primary' && r.status !== 'disabled') ?? null;
    return {
      clusterId: 'local',
      epoch: primary?.epoch ?? 1,
      primary: primary
        ? { nodeId: primary.id, endpoint: primary.endpoint, since: primary.last_heartbeat_at }
        : null,
      readEndpoints: rows
        .filter((r) => r.status === 'online' || r.status === 'syncing')
        .map((r) => ({ nodeId: r.id, endpoint: r.endpoint, lagMs: 0 })),
      ttlSeconds: 60,
    };
  });

  await registerAuthRoutes(app);
  await registerDiaryRoutes(app);
  await registerSyncRoutes(app);
  await registerMediaRoutes(app);
  await registerAdminRoutes(app);
  await registerAdminWeb(app);
  await registerRecoveryRoutes(app);
  await registerReplicationRoutes(app);
  return app;
}
