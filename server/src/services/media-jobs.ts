/**
 * 媒体归一化队列（需求 5.2）。
 *
 * 目标：把 iPhone 的 .mov、录屏的 .webm、杂牌 .wav 这类文件转成 H.264/AAC 的 mp4，
 * 保证换设备也能播放。
 *
 * 现实约束：
 *   * 转码需要 ffmpeg，它是几十 MB 的外部二进制，很多部署不装；
 *   * 没装时**绝不阻塞上传**，文件按原样保存，任务标记为 skipped 并写明原因；
 *   * 客户端据此显示"处理中"或"原始格式"的提示。
 *
 * 这样：装了 ffmpeg 的部署能享受归一化，没装的也不会因此坏掉。
 */
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { pool } from '../db/pool.ts';
/** 轻量日志：服务层不依赖 Fastify 实例 */
const logger = {
  info: (obj: unknown, msg: string) => console.info(`${msg} ${JSON.stringify(obj)}`),
  warn: (obj: unknown, msg: string) => console.warn(`${msg} ${JSON.stringify(obj)}`),
};

/** 需要归一化的 MIME：这些格式跨平台播放不可靠 */
const NEEDS_NORMALIZE: Record<string, 'video' | 'audio'> = {
  'video/quicktime': 'video',
  'video/x-msvideo': 'video',
  'video/x-matroska': 'video',
  'video/webm': 'video',
  'video/mpeg': 'video',
  'audio/wav': 'audio',
  'audio/x-wav': 'audio',
  'audio/wave': 'audio',
  'audio/webm': 'audio',
  'audio/ogg': 'audio',
};

export function needsNormalize(mime: string): boolean {
  return mime in NEEDS_NORMALIZE;
}

/** 探测 ffmpeg 是否可用。只在启动时做一次。 */
let ffmpegPath: string | null = null;
let ffmpegProbed = false;

export function detectFfmpeg(): string | null {
  if (ffmpegProbed) return ffmpegPath;
  ffmpegProbed = true;
  const candidates = [process.env.RJJ_FFMPEG_BIN, 'ffmpeg'].filter(Boolean) as string[];
  for (const candidate of candidates) {
    if (candidate !== 'ffmpeg' && !existsSync(candidate)) continue;
    const probe = spawnSync(candidate, ['-version'], { encoding: 'utf8' });
    if (probe.status === 0) {
      ffmpegPath = candidate;
      logger.info({ ffmpeg: candidate }, '[media] 检测到 ffmpeg，已启用媒体归一化');
      return ffmpegPath;
    }
  }
  logger.warn({}, '[media] 未检测到 ffmpeg：媒体将保留原始格式，跨平台播放可能不兼容');
  return null;
}

/** 上传后调用：需要归一化的才入队 */
export async function enqueueIfNeeded(
  userId: string,
  mediaKey: string,
  mime: string,
): Promise<void> {
  if (!needsNormalize(mime)) return;
  try {
    await pool.query(
      `INSERT INTO media_jobs (user_id, media_key, mime, status)
       VALUES ($1, $2, $3, 'pending')
       ON CONFLICT (user_id, media_key) DO NOTHING`,
      [userId, mediaKey, mime],
    );
  } catch (err) {
    // 入队失败不能影响上传结果
    logger.warn({ err, mediaKey }, '[media] 入队失败');
  }
}

/** 查询某媒体当前的处理状态 */
export async function getJobStatus(
  userId: string,
  mediaKey: string,
): Promise<{ status: string; reason: string | null } | null> {
  const { rows } = await pool.query<{ status: string; reason: string | null }>(
    'SELECT status, reason FROM media_jobs WHERE user_id = $1 AND media_key = $2',
    [userId, mediaKey],
  );
  const row = rows[0];
  if (!row) return null;
  return { status: row.status, reason: row.reason };
}

/** 处理一条任务：有 ffmpeg 就转码，没有就标记跳过 */
async function processJob(job: {
  id: string;
  user_id: string;
  media_key: string;
  mime: string;
}): Promise<void> {
  const bin = detectFfmpeg();
  if (!bin) {
    await pool.query(
      `UPDATE media_jobs SET status = 'skipped', reason = $2, updated_at = now() WHERE id = $1`,
      [job.id, '服务器未安装 ffmpeg，文件按原始格式保存'],
    );
    return;
  }

  // 端到端加密的媒体在磁盘上是密文，服务端转码会直接损坏数据。
  // 这类任务直接跳过：客户端上传时已是它自己处理的格式。
  const owner = await pool.query<{ enc: string | null }>(
    'SELECT enc FROM media WHERE user_id = $1 AND media_key = $2',
    [job.user_id, job.media_key],
  );
  const enc = owner.rows[0]?.enc ?? 'none';
  if (enc !== 'none') {
    await pool.query(
      `UPDATE media_jobs SET status = 'skipped', reason = $2, updated_at = now() WHERE id = $1`,
      [job.id, '媒体已端到端加密，服务端无法转码（需要保留原始格式）'],
    );
    return;
  }

  // 有 ffmpeg 时才会走到这里。转码本身交给 ffmpeg，失败则记下原因、保留原文件。
  await pool.query(
    `UPDATE media_jobs SET status = 'processing', attempts = attempts + 1, updated_at = now() WHERE id = $1`,
    [job.id],
  );
  try {
    await runFfmpeg(bin, job.user_id, job.media_key);
    await pool.query(
      `UPDATE media_jobs SET status = 'done', reason = NULL, updated_at = now() WHERE id = $1`,
      [job.id],
    );
  } catch (err) {
    await pool.query(
      `UPDATE media_jobs SET status = 'failed', reason = $2, updated_at = now() WHERE id = $1`,
      [job.id, err instanceof Error ? err.message.slice(0, 300) : String(err).slice(0, 300)],
    );
  }
}

/** 实际调用 ffmpeg。转码后覆盖原文件的位置（客户端缓存会重新拉取）。 */
async function runFfmpeg(bin: string, userId: string, mediaKey: string): Promise<void> {
  const { rows } = await pool.query<{ blob_path: string; mime: string }>(
    'SELECT blob_path, mime FROM media WHERE user_id = $1 AND media_key = $2',
    [userId, mediaKey],
  );
  const media = rows[0];
  if (!media) throw new Error('媒体记录不存在');

  const isVideo = media.mime.startsWith('video/');
  const args = isVideo
    ? ['-y', '-i', media.blob_path, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
       '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', `${media.blob_path}.tmp.mp4`]
    : ['-y', '-i', media.blob_path, '-c:a', 'aac', '-b:a', '128k', `${media.blob_path}.tmp.m4a`];

  await new Promise<void>((resolve, reject) => {
    const proc = spawn(bin, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    proc.stderr.on('data', (chunk) => {
      stderr += String(chunk);
      if (stderr.length > 4000) stderr = stderr.slice(-4000);
    });
    proc.on('error', reject);
    proc.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg 退出码 ${code}：${stderr.split('\n').slice(-3).join(' ')}`));
    });
  });

  const produced = `${media.blob_path}${isVideo ? '.tmp.mp4' : '.tmp.m4a'}`;
  const { renameSync, unlinkSync } = await import('node:fs');
  try {
    unlinkSync(media.blob_path);
  } catch {
    // 原文件删不掉就继续，rename 会覆盖
  }
  renameSync(produced, media.blob_path);
  const { statSync } = await import('node:fs');
  const newSize = statSync(media.blob_path).size;
  await pool.query(
    `UPDATE media SET mime = $3, byte_size = $4 WHERE user_id = $1 AND media_key = $2`,
    [userId, mediaKey, isVideo ? 'video/mp4' : 'audio/mp4', newSize],
  );
}

/**
 * 后台循环：一次处理一批任务。
 * 用简单的轮询而不是消息队列——个人日记的量级不需要更重的基础设施。
 */
export function startMediaWorker(intervalMs = 15_000): () => void {
  let stopped = false;
  let running = false;

  const tick = async (): Promise<void> => {
    if (stopped || running) return;
    running = true;
    try {
      const { rows } = await pool.query<{
        id: string;
        user_id: string;
        media_key: string;
        mime: string;
      }>(
        `SELECT id, user_id, media_key, mime FROM media_jobs
          WHERE status = 'pending' ORDER BY created_at ASC LIMIT 5`,
      );
      for (const job of rows) {
        if (stopped) break;
        await processJob(job);
      }
    } catch (err) {
      logger.warn({ err }, '[media] 队列处理失败');
    } finally {
      running = false;
    }
  };

  const timer = setInterval(() => void tick(), intervalMs);
  timer.unref?.();
  void tick();

  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
