/**
 * 媒体上传与下载。
 * 上传走流式（不把整个视频读进内存），下载支持 Range（视频拖动进度条必需）。
 * 媒体以"用户 + 客户端算出的 keyed hash"为键，服务端只见密文与元数据（需求 4.2 / 6.1）。
 */
import type { FastifyInstance } from 'fastify';
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, rename, stat, unlink } from 'node:fs/promises';
import path from 'node:path';
import { Transform, type Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { config } from '../config.ts';
import { enqueueIfNeeded, getJobStatus, needsNormalize } from '../services/media-jobs.ts';
import { assertWithinQuota, getUsage } from '../services/quota.ts';
import { pool } from '../db/pool.ts';
import { AppError } from '../http/errors.ts';
import { currentUserId, requireAuth } from '../http/auth-guard.ts';

const KEY_RE = /^[0-9a-f]{16,128}$/;

function blobDir(userId: string): string {
  return path.join(config.mediaDir, userId.slice(0, 2), userId);
}

function blobPath(userId: string, mediaKey: string): string {
  return path.join(blobDir(userId), `${mediaKey}.bin`);
}

function strHeader(value: unknown): string | null {
  const raw = Array.isArray(value) ? value[0] : value;
  return typeof raw === 'string' && raw.length > 0 ? raw : null;
}

function intHeader(value: unknown): number | null {
  const raw = strHeader(value);
  if (raw === null) return null;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) ? n : null;
}

export async function registerMediaRoutes(app: FastifyInstance): Promise<void> {
  app.post('/api/media', { preHandler: requireAuth }, async (req, reply) => {
    const userId = currentUserId(req);
    const rawKey = strHeader(req.headers['x-media-key']);
    if (!rawKey || !KEY_RE.test(rawKey.toLowerCase())) {
      throw AppError.badRequest('缺少或非法的 x-media-key（应为 16~128 位十六进制）');
    }
    const mediaKey = rawKey.toLowerCase();

    const mime = strHeader(req.headers['x-media-mime']) ?? 'application/octet-stream';
    const encHeader = strHeader(req.headers['x-media-enc']) ?? 'none';
    if (encHeader !== 'none' && encHeader !== 'aes-256-gcm') {
      throw AppError.badRequest('x-media-enc 只能是 none 或 aes-256-gcm');
    }
    const nonceB64 = strHeader(req.headers['x-media-nonce']);
    const nonce = nonceB64 ? Buffer.from(nonceB64, 'base64') : null;
    const durationMs = intHeader(req.headers['x-media-duration']);
    const width = intHeader(req.headers['x-media-width']);
    const height = intHeader(req.headers['x-media-height']);

    const body = req.body as Readable | undefined;
    if (!body || typeof (body as Readable).pipe !== 'function') {
      throw AppError.badRequest('请求体必须是二进制流（Content-Type: application/octet-stream）');
    }

    const dir = blobDir(userId);
    await mkdir(dir, { recursive: true });
    const target = blobPath(userId, mediaKey);
    const tmp = `${target}.${process.pid}.${Date.now()}.part`;

    const hash = createHash('sha256');
    let bytes = 0;
    const meter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        bytes += chunk.length;
        if (bytes > config.maxUploadBytes) {
          callback(AppError.tooLarge(`媒体超过单文件上限 ${config.maxUploadBytes} 字节`));
          return;
        }
        hash.update(chunk);
        callback(null, chunk);
      },
    });

    try {
      await pipeline(body, meter, createWriteStream(tmp));
    } catch (err) {
      await unlink(tmp).catch(() => undefined);
      throw err;
    }
    await rename(tmp, target);

    const alreadyKnown = await pool.query('SELECT 1 FROM media WHERE user_id = $1 AND media_key = $2', [
      userId,
      mediaKey,
    ]);

    // 配额检查与写入放在同一事务里，并对用户行加锁：
    // 否则两个并发上传可能同时通过检查，把空间撑爆。
    const quotaClient = await pool.connect();
    try {
      await quotaClient.query('BEGIN');
      const existing = await quotaClient.query<{ byte_size: string }>(
        'SELECT byte_size FROM media WHERE user_id = $1 AND media_key = $2',
        [userId, mediaKey],
      );
      const replacing = Number(existing.rows[0]?.byte_size ?? 0);
      await assertWithinQuota(quotaClient, userId, bytes, replacing);
      await quotaClient.query(
        `INSERT INTO media (user_id, media_key, byte_size, mime, enc, nonce, duration_ms, width, height, blob_path)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
         ON CONFLICT (user_id, media_key) DO UPDATE
           SET byte_size = EXCLUDED.byte_size,
               mime = EXCLUDED.mime,
               enc = EXCLUDED.enc,
               nonce = COALESCE(EXCLUDED.nonce, media.nonce),
               duration_ms = COALESCE(EXCLUDED.duration_ms, media.duration_ms),
               width = COALESCE(EXCLUDED.width, media.width),
               height = COALESCE(EXCLUDED.height, media.height)`,
        [userId, mediaKey, bytes, mime, encHeader, nonce, durationMs, width, height, target],
      );
      await quotaClient.query('COMMIT');
    } catch (err) {
      await quotaClient.query('ROLLBACK').catch(() => undefined);
      // 超配额时把刚写好的文件删掉，别留下孤儿文件
      await unlink(target).catch(() => undefined);
      throw err;
    } finally {
      quotaClient.release();
    }
    // 需要跨平台归一化的格式才入队；失败不影响上传结果
    await enqueueIfNeeded(userId, mediaKey, mime);

    return reply.send({
      mediaKey,
      needsNormalize: needsNormalize(mime),
      bytes,
      mime,
      enc: encHeader,
      sha256: hash.digest('hex'),
      deduped: alreadyKnown.rows.length > 0,
    });
  });

  /** 当前用户的存储用量与配额（客户端用来提示快满了） */
  app.get('/api/me/storage', { preHandler: requireAuth }, async (req) => {
    const usage = await getUsage(currentUserId(req));
    return usage;
  });
  /** 已存在检查：客户端上传前先问，避免重复传同一段视频 */
  app.head('/api/media/:key', { preHandler: requireAuth }, async (req, reply) => {
    const userId = currentUserId(req);
    const key = ((req.params as { key: string }).key ?? '').toLowerCase();
    if (!KEY_RE.test(key)) return reply.code(400).send();
    const { rows } = await pool.query('SELECT byte_size FROM media WHERE user_id = $1 AND media_key = $2', [
      userId,
      key,
    ]);
    if (rows.length === 0) return reply.code(404).send();
    return reply.header('content-length', String(rows[0].byte_size)).code(200).send();
  });

  /** 某媒体的归一化处理状态（需求 5.2：界面显示"处理中/原始格式"） */
  app.get('/api/media/:key/status', { preHandler: requireAuth }, async (req) => {
    const { key } = req.params as { key: string };
    const job = await getJobStatus(currentUserId(req), key.toLowerCase());
    if (!job) return { status: 'none', reason: null };
    return job;
  });

  app.get('/api/media/:key', { preHandler: requireAuth }, async (req, reply) => {
    const userId = currentUserId(req);
    const key = ((req.params as { key: string }).key ?? '').toLowerCase();
    if (!KEY_RE.test(key)) throw AppError.badRequest('非法媒体键');

    const { rows } = await pool.query<{
      mime: string | null;
      enc: string;
      nonce: Buffer | null;
      byte_size: string;
    }>('SELECT mime, enc, nonce, byte_size FROM media WHERE user_id = $1 AND media_key = $2', [userId, key]);
    const row = rows[0];
    if (!row) throw AppError.notFound('媒体不存在');

    const file = blobPath(userId, key);
    const info = await stat(file).catch(() => null);
    if (!info) throw AppError.notFound('媒体文件缺失');

    reply
      .header('accept-ranges', 'bytes')
      .header('content-type', row.mime ?? 'application/octet-stream')
      .header('cache-control', 'private, max-age=31536000, immutable')
      .header('x-media-enc', row.enc);
    if (row.nonce) reply.header('x-media-nonce', row.nonce.toString('base64'));

    const range = strHeader(req.headers.range);
    if (range) {
      const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
      if (m) {
        const start = m[1] ? Number.parseInt(m[1], 10) : 0;
        const end = m[2] ? Math.min(Number.parseInt(m[2], 10), info.size - 1) : info.size - 1;
        if (start <= end && start < info.size) {
          return reply
            .code(206)
            .header('content-range', `bytes ${start}-${end}/${info.size}`)
            .header('content-length', String(end - start + 1))
            .send(createReadStream(file, { start, end }));
        }
        return reply.code(416).header('content-range', `bytes */${info.size}`).send();
      }
    }

    return reply.header('content-length', String(info.size)).send(createReadStream(file));
  });
}
