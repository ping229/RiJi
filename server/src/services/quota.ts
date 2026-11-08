/**
 * 用户存储配额（需求：管理员可限制每个账号能占多少空间）。
 *
 * 只统计媒体文件的字节数：文字日记很小，真正吃磁盘的是图片和视频。
 * 判定在写入媒体的事务里做，并对用户行加锁，避免并发上传同时通过检查。
 */
import type { PoolClient } from 'pg';
import { pool } from '../db/pool.ts';
import { AppError } from '../http/errors.ts';
import { config } from '../config.ts';

export interface StorageUsage {
  usedBytes: number;
  quotaBytes: number | null;
  fileCount: number;
  percent: number;
}

/** 把字节数变成人能读的形式：4.7 GB / 320 MB */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = value >= 100 || unit === 0 ? 0 : 1;
  return `${value.toFixed(digits)} ${units[unit]}`;
}

/** 查询某个用户的用量（不含未提交的上传） */
export async function getUsage(userId: string, client?: PoolClient): Promise<StorageUsage> {
  const runner = client ?? pool;
  const { rows } = await runner.query<{ used: string; files: string; quota: string | null }>(
    `SELECT COALESCE(SUM(byte_size), 0) AS used,
            COUNT(*) AS files,
            (SELECT quota_bytes FROM users WHERE id = $1) AS quota
       FROM media WHERE user_id = $1`,
    [userId],
  );
  const usedBytes = Number(rows[0]?.used ?? 0);
  const quotaRaw = rows[0]?.quota;
  const quotaBytes = quotaRaw === null || quotaRaw === undefined ? null : Number(quotaRaw);
  const percent = quotaBytes && quotaBytes > 0 ? Math.min(100, (usedBytes / quotaBytes) * 100) : 0;
  return {
    usedBytes,
    quotaBytes,
    fileCount: Number(rows[0]?.files ?? 0),
    percent,
  };
}

/**
 * 检查这次上传会不会超配额。在事务里调用，并对用户行加锁。
 * @param incomingBytes 本次要写入的字节数
 * @param replacingBytes 同一 mediaKey 已存在时，旧文件会被覆盖，可抵扣
 */
export async function assertWithinQuota(
  client: PoolClient,
  userId: string,
  incomingBytes: number,
  replacingBytes = 0,
): Promise<void> {
  const { rows } = await client.query<{ quota_bytes: string | null }>(
    'SELECT quota_bytes FROM users WHERE id = $1 FOR UPDATE',
    [userId],
  );
  const quotaRaw = rows[0]?.quota_bytes;
  if (quotaRaw === null || quotaRaw === undefined) return; // 不限制
  const quota = Number(quotaRaw);
  if (quota <= 0) return; // 0 视为不限制，避免误配置把账号卡死

  const usedResult = await client.query<{ used: string }>(
    'SELECT COALESCE(SUM(byte_size), 0) AS used FROM media WHERE user_id = $1',
    [userId],
  );
  const used = Number(usedResult.rows[0]?.used ?? 0);
  const projected = used - replacingBytes + incomingBytes;
  if (projected <= quota) return;

  const over = projected - quota;
  throw AppError.tooLarge(
    `存储空间不足：已用 ${formatBytes(used)}，配额 ${formatBytes(quota)}，`
    + `本次需要 ${formatBytes(incomingBytes)}（还差 ${formatBytes(over)}）。`
    + '可以删除一些图片/视频，或联系管理员调整配额。',
    'QUOTA_EXCEEDED',
    {
      usedBytes: used,
      quotaBytes: quota,
      incomingBytes,
      remainingBytes: Math.max(0, quota - used),
    },
  );
}

/** 新用户默认配额（可用 RJJ_DEFAULT_QUOTA_GB 覆盖；0 表示不限制） */
export function defaultQuotaBytes(): number | null {
  const gb = config.defaultQuotaGb;
  if (!Number.isFinite(gb) || gb <= 0) return null;
  return Math.round(gb * 1024 * 1024 * 1024);
}
