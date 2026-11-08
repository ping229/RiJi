/**
 * 节点间通信客户端。
 *
 * 配了 RJJ_TLS_DIR 就走 mTLS（双向证书校验），否则退回普通 HTTP。
 * 生产环境必须用 mTLS：共享令牌一旦泄漏，任何人都能伪装成节点拉走全量数据。
 */
import https from 'node:https';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { config } from '../config.ts';

export interface ReplicationResponse {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  bytes: Buffer;
  json: <T = unknown>() => T;
}

let cachedAgent: https.Agent | null = null;

export function tlsEnabled(): boolean {
  return Boolean(config.replicationTlsDir);
}

function tlsPaths(): { ca: string; cert: string; key: string } {
  const dir = config.replicationTlsDir!;
  return {
    ca: path.join(dir, 'ca.crt.pem'),
    cert: path.join(dir, `${config.nodeId}.crt.pem`),
    key: path.join(dir, `${config.nodeId}.key.pem`),
  };
}

export function assertTlsFilesPresent(): void {
  if (!tlsEnabled()) return;
  const paths = tlsPaths();
  for (const [label, file] of Object.entries(paths)) {
    if (!existsSync(file)) {
      throw new Error(`mTLS 已启用但缺少 ${label} 文件：${file}`);
    }
  }
}

function agent(): https.Agent {
  if (cachedAgent) return cachedAgent;
  const paths = tlsPaths();
  cachedAgent = new https.Agent({
    ca: readFileSync(paths.ca),
    cert: readFileSync(paths.cert),
    key: readFileSync(paths.key),
    rejectUnauthorized: true,
    keepAlive: true,
  });
  return cachedAgent;
}

/** 统一入口：根据目标协议与配置选择 mTLS 或普通请求 */
export async function replicationRequest(
  url: string,
  options: {
    method?: string;
    body?: string;
    headers?: Record<string, string>;
    timeoutMs?: number;
  } = {},
): Promise<ReplicationResponse> {
  const timeoutMs = options.timeoutMs ?? 30_000;
  const headers: Record<string, string> = {
    'x-replication-token': config.replicationToken,
    ...(options.body ? { 'content-type': 'application/json' } : {}),
    ...options.headers,
  };

  const isHttps = url.startsWith('https://');
  if (!isHttps) {
    const res = await fetch(url, {
      method: options.method ?? 'GET',
      headers,
      body: options.body,
      signal: AbortSignal.timeout(timeoutMs),
    });
    const bytes = Buffer.from(await res.arrayBuffer());
    return {
      status: res.status,
      headers: Object.fromEntries(res.headers.entries()),
      bytes,
      json: <T>() => JSON.parse(bytes.toString('utf8')) as T,
    };
  }

  return new Promise<ReplicationResponse>((resolve, reject) => {
    const target = new URL(url);
    const req = https.request(
      {
        hostname: target.hostname,
        port: target.port || 443,
        path: `${target.pathname}${target.search}`,
        method: options.method ?? 'GET',
        headers,
        agent: agent(),
        timeout: timeoutMs,
        servername: target.hostname,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => {
          const bytes = Buffer.concat(chunks);
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            bytes,
            json: <T>() => JSON.parse(bytes.toString('utf8')) as T,
          });
        });
      },
    );

    req.on('timeout', () => req.destroy(new Error(`请求超时：${url}`)));
    req.on('error', reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}
