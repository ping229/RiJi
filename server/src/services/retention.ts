/**
 * 数据保留与清理。
 *
 * 有三张表会随着使用无限增长，之前只有注释写着"30 天后清理"，但没有任何代码：
 *   * block_versions  —— 冲突落败/被覆盖的历史版本（保留 30 天，列里已有 retained_until）
 *   * changes         —— 客户端增量同步游标（客户端目前并不消费，留 30 天足够）
 *   * replication_log —— 节点复制日志（必须保留到最落后的副本都读过）
 *
 * 清理必须保守：复制日志按「所有副本游标的最小值」来删，
 * 删快了副本就永久缺数据。没有副本时只保留最近若干天，反正新节点靠基线快照加入。
 */
import { pool } from '../db/pool.ts';
import { config } from '../config.ts';

export interface RetentionResult {
  blockVersions: number;
  changes: number;
  replicationLog: number;
}

/** 执行一轮清理，返回各表删除行数 */
export async function runRetentionOnce(): Promise<RetentionResult> {
  const versions = await pool.query(
    'DELETE FROM block_versions WHERE retained_until < now()',
  );

  const changes = await pool.query(
    `DELETE FROM changes WHERE created_at < now() - interval '30 days'`,
  );

  // 有副本时：只删"所有副本都已经读过"的部分；没副本时才按时间删
  const { rows } = await pool.query<{ cursor: string | null; nodes: number }>(
    `SELECT MIN(cursor)::text AS cursor, count(*)::int AS nodes FROM replication_state`,
  );
  const state = rows[0];
  const minCursor = Number(state?.cursor ?? 0);
  const hasReplicas = (state?.nodes ?? 0) > 0;

  const log = hasReplicas
    ? await pool.query(
        `DELETE FROM replication_log
          WHERE seq <= $1 AND created_at < now() - interval '1 day'`,
        [minCursor],
      )
    : await pool.query(
        `DELETE FROM replication_log
          WHERE created_at < now() - interval '7 days'`,
      );

  return {
    blockVersions: versions.rowCount ?? 0,
    changes: changes.rowCount ?? 0,
    replicationLog: log.rowCount ?? 0,
  };
}

/**
 * 后台清理循环：启动后先跑一次，之后每 6 小时一次。
 * 任何一次失败只记日志，不影响服务。
 */
export function startRetentionWorker(log: {
  info: (msg: string) => void;
  error: (msg: string) => void;
}): () => void {
  let stopped = false;
  let timer: NodeJS.Timeout | null = null;
  const intervalMs = Math.max(1, config.retentionIntervalHours) * 3600_000;

  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      const result = await runRetentionOnce();
      const total = result.blockVersions + result.changes + result.replicationLog;
      if (total > 0) {
        log.info(
          `[retention] 清理完成：历史版本 ${result.blockVersions} 行、`
            + `变更日志 ${result.changes} 行、复制日志 ${result.replicationLog} 行`,
        );
      }
    } catch (err) {
      log.error(`[retention] 清理失败：${(err as Error).message}`);
    }
    if (!stopped) timer = setTimeout(tick, intervalMs);
  };

  // 启动 30 秒后再跑，避免和迁移、基线同步抢数据库
  timer = setTimeout(tick, 30_000);
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
