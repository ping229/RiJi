/**
 * 管理员 Web 后台的静态资源服务。
 * 后台是纯静态页面（无构建步骤），由 API 服务直接托管在 /admin。
 */
import type { FastifyInstance } from 'fastify';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const adminDir = path.resolve(here, '../../../admin');

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
};

export async function registerAdminWeb(app: FastifyInstance): Promise<void> {
  const send = async (file: string, reply: import('fastify').FastifyReply) => {
    try {
      const body = await readFile(path.join(adminDir, file));
      const ext = path.extname(file);
      reply.header('cache-control', 'no-cache');
      return reply.type(TYPES[ext] ?? 'application/octet-stream').send(body);
    } catch {
      return reply.code(404).type('text/plain; charset=utf-8').send('后台资源缺失');
    }
  };

  app.get('/admin', (_req, reply) => send('index.html', reply));
  app.get('/admin/', (_req, reply) => send('index.html', reply));
  app.get('/admin/app.js', (_req, reply) => send('app.js', reply));
  app.get('/admin/style.css', (_req, reply) => send('style.css', reply));
}
