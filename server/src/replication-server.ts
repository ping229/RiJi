/**
 * 节点间 mTLS 服务（需求 10.4 / 10.5）。
 *
 * 单独监听一个端口（默认 9443），只接受持有本集群 CA 签发证书的节点连接。
 * 与面向客户端的 8080/443 分开，便于防火墙只对其他节点 IP 开放 9443。
 */
import Fastify, { type FastifyInstance } from 'fastify';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { config } from './config.ts';
import { registerReplicationRoutes } from './routes/replication.ts';

export interface TlsLogger {
  info: (msg: string) => void;
  error: (msg: string) => void;
}

export async function startReplicationTlsServer(log: TlsLogger): Promise<FastifyInstance | null> {
  if (!config.replicationTlsDir) return null;

  const dir = config.replicationTlsDir;
  const keyPath = path.join(dir, `${config.nodeId}.key.pem`);
  const certPath = path.join(dir, `${config.nodeId}.crt.pem`);
  const caPath = path.join(dir, 'ca.crt.pem');

  let httpsOptions: { key: Buffer; cert: Buffer; ca: Buffer; requestCert: boolean; rejectUnauthorized: boolean };
  try {
    httpsOptions = {
      key: readFileSync(keyPath),
      cert: readFileSync(certPath),
      ca: readFileSync(caPath),
      // 双向校验：既验证对方证书由本集群 CA 签发，也要求对方出示证书
      requestCert: true,
      rejectUnauthorized: true,
    };
  } catch (err) {
    log.error(`[mTLS] 证书读取失败：${(err as Error).message}`);
    return null;
  }

  const app = Fastify({ logger: { level: config.logLevel }, https: httpsOptions });

  app.addHook('onRequest', async (request) => {
    const socket = request.raw.socket as unknown as {
      getPeerCertificate?: () => { subject?: { CN?: string } };
    };
    const peer = socket.getPeerCertificate?.();
    const cn = peer?.subject?.CN;
    if (cn) request.log.debug(`[mTLS] 对端节点：${cn}`);
  });

  // 只挂复制相关路由，不暴露任何用户接口
  await registerReplicationRoutes(app);

  await app.listen({ port: config.replicationPort, host: '0.0.0.0' });
  log.info(`[mTLS] 节点间通道已启用：0.0.0.0:${config.replicationPort}（仅接受本集群 CA 签发的证书）`);
  return app;
}
