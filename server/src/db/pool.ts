import pg from 'pg';
import { config } from '../config.ts';

// PostgreSQL 的 DATE 列默认会被驱动解析成本地时区午夜的 Date 对象，
// 再用 UTC 取值就会偏移一天（"2026-11-03" 变成 "2026-11-02"）。
// 日记的归属日期是纯日历日，必须原样以字符串返回，绝不能参与时区换算。
pg.types.setTypeParser(1082, (value: string) => value);

/**
 * PostgreSQL 连接池。所有 SQL 都走这里，便于统一加超时与慢查询日志。
 */
export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (err) => {
  // 连接池级别的异常不能静默，否则数据库抖动会表现为"随机 500"
  console.error('[db] idle client error', err);
});

export type Queryable = Pick<pg.PoolClient, 'query'> | typeof pool;

/** 在一个事务里跑一组操作；回调抛错则整体回滚 */
export async function withTransaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch {
      /* 回滚失败时保留原始错误 */
    }
    throw err;
  } finally {
    client.release();
  }
}

export async function closePool(): Promise<void> {
  await pool.end();
}

export type { pg };
