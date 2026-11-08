/**
 * 配置：全部来自环境变量，带本地开发默认值。
 * 生产部署时由 docker-compose / .env 注入。
 */
import path from 'node:path';

function env(name: string, fallback: string): string {
  const v = process.env[name];
  return v === undefined || v === '' ? fallback : v;
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n)) throw new Error(`环境变量 ${name} 不是合法整数: ${raw}`);
  return n;
}

export const config = {
  /** HTTP 监听端口。需求 10.5：8080 仅供本机，公网走 443 反代 */
  port: envInt('RJJ_PORT', 8080),
  host: env('RJJ_HOST', '127.0.0.1'),
  databaseUrl: env('RJJ_DATABASE_URL', 'postgres://diary@127.0.0.1:5544/riji'),
  /** 媒体密文存放目录 */
  mediaDir: env('RJJ_MEDIA_DIR', path.join(process.cwd(), 'var', 'media')),
  /** JWT 签名密钥，生产必须覆盖 */
  jwtSecret: env('RJJ_JWT_SECRET', 'dev-only-secret-change-me'),
  accessTokenTtlSeconds: envInt('RJJ_ACCESS_TTL', 60 * 60 * 12),
  refreshTokenTtlSeconds: envInt('RJJ_REFRESH_TTL', 60 * 60 * 24 * 30),
  /** 单次媒体上传上限（字节），默认 512MB */
  maxUploadBytes: envInt('RJJ_MAX_UPLOAD', 512 * 1024 * 1024),

  /// 新用户默认存储配额（GB），0 表示不限制
  defaultQuotaGb: envInt('RJJ_DEFAULT_QUOTA_GB', 5),
  /** 日切点默认值，单位小时（需求 3.1，默认 04:00） */
  dayCutHour: envInt('RJJ_DAY_CUT_HOUR', 4),
  /** 写窗口：今天 + 过去 N 天 */
  writeWindowDays: envInt('RJJ_WRITE_WINDOW_DAYS', 7),
  /** 时钟偏差阈值：超过则标记 time_suspect（需求 3.1） */
  clockSkewThresholdSeconds: envInt('RJJ_CLOCK_SKEW_SECONDS', 300),
  /** 本节点标识，多节点部署时各不相同 */
  nodeId: env('RJJ_NODE_ID', 'node-local'),
  nodeRole: env('RJJ_NODE_ROLE', 'primary'),
  /** 副本用：主节点地址 */
  primaryUrl: env('RJJ_PRIMARY_URL', ''),
  /** 节点间复制用的共享令牌（启用 mTLS 后仅作第二道校验） */
  replicationToken: env('RJJ_REPLICATION_TOKEN', 'dev-replication-token'),
  /** 证书目录：包含 ca.crt.pem、<nodeId>.crt.pem、<nodeId>.key.pem。配置后启用 mTLS */
  replicationTlsDir: env('RJJ_TLS_DIR', ''),
  /** 节点间 mTLS 监听端口（需求 10.5：仅对其他节点可达） */
  replicationPort: envInt('RJJ_REPLICATION_PORT', 9443),
  /** 后台清理任务（历史版本/变更日志/复制日志）的执行间隔，单位小时 */
  retentionIntervalHours: envInt('RJJ_RETENTION_INTERVAL_HOURS', 6),
  logLevel: env('RJJ_LOG_LEVEL', 'info'),
} as const;

export type AppConfig = typeof config;
