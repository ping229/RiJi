/**
 * 服务端启动入口。
 * 启动顺序：建表 → 建初始管理员 → 注册本节点 → 监听端口。
 */
import { buildApp } from './app.ts';
import { config } from './config.ts';
import { runMigrations } from './db/migrate.ts';
import { closePool, pool } from './db/pool.ts';
import { ensureBootstrapAdmin } from './bootstrap.ts';
import { bootstrapFromPrimary, repairMediaMetadata, startReplicaWorker, syncMissingMedia } from './services/replication.ts';
import { detectFfmpeg, startMediaWorker } from './services/media-jobs.ts';
import { startRetentionWorker } from './services/retention.ts';
import { startReplicationTlsServer } from './replication-server.ts';

async function ensureLocalNode(): Promise<void> {
  await pool.query(
    `INSERT INTO nodes (id, role, status, endpoint, last_heartbeat_at)
     VALUES ($1, $2, 'online', $3, now())
     ON CONFLICT (id) DO UPDATE
       SET role = EXCLUDED.role,
           status = CASE WHEN nodes.status = 'disabled' THEN nodes.status ELSE 'online' END,
           endpoint = EXCLUDED.endpoint,
           last_heartbeat_at = now()`,
    [config.nodeId, config.nodeRole, `http://${config.host}:${config.port}`],
  );
}

async function main(): Promise<void> {
  await runMigrations();
  const app = await buildApp();
  const bootstrap = await ensureBootstrapAdmin(app.log);
  await ensureLocalNode();

  await app.listen({ port: config.port, host: config.host });

  const address = `http://${config.host}:${config.port}`;
  app.log.info(`RiJi 服务端已启动：${address}（节点 ${config.nodeId} / ${config.nodeRole}）`);

  // 节点间 mTLS 通道（配置了 RJJ_TLS_DIR 才启用）
  // 监听失败不能拖垮整个节点：副本即便自己不能被连入，也要能主动向外拉取。
  let tlsApp = null;
  try {
    tlsApp = await startReplicationTlsServer({
      info: (msg) => app.log.info(msg),
      error: (msg) => app.log.error(msg),
    });
  } catch (err) {
    app.log.error(`[mTLS] 通道启动失败（节点继续运行）：${(err as Error).message}`);
  }

  // 副本节点启动追平循环
  let stopReplica: (() => void) | null = null;

  // 媒体归一化只在主节点跑：副本只要把文件复制过去就行，不需要重复转码
  let stopMediaWorker: (() => void) | undefined;
  if (config.nodeRole === 'primary') {
    detectFfmpeg();
    stopMediaWorker = startMediaWorker();
  }

  // 历史版本 / 变更日志 / 复制日志的定期清理（主节点才需要）
  let stopRetention: (() => void) | undefined;
  if (config.nodeRole === 'primary') {
    stopRetention = startRetentionWorker({
      info: (msg) => app.log.info(msg),
      error: (msg) => app.log.error(msg),
    });
  }

  if (config.nodeRole === 'replica') {
    if (!config.primaryUrl) {
      app.log.error('本节点是副本，但没有配置 RJJ_PRIMARY_URL，无法追平主节点');
    } else {
      try {
        const boot = await bootstrapFromPrimary();
        if (boot.diaries > 0 || boot.blocks > 0) {
          app.log.info(`基线同步完成：${boot.diaries} 篇日记、${boot.blocks} 个块`);
        }
        const media = await syncMissingMedia();
        if (media > 0) app.log.info(`基线媒体补齐：${media} 个文件`);
        // 修历史遗留：早期复制的加密媒体缺 nonce，副本上解不开
        const repaired = await repairMediaMetadata();
        if (repaired > 0) app.log.info(`媒体元数据修补：${repaired} 个`);
      } catch (err) {
        app.log.error(`基线同步失败：${(err as Error).message}`);
      }
      stopReplica = startReplicaWorker({
        info: (msg) => app.log.info(msg),
        error: (msg) => app.log.error(msg),
      });
      app.log.info(`副本追平已启动，主节点：${config.primaryUrl}`);
    }
  }

  if (bootstrap.created) {
    // 首次启动时把初始账号信息直接打在控制台，避免用户找不到
    process.stdout.write(
      [
        '',
        '======================================================',
        '  首次启动，已创建管理员账号',
        `  用户名：${bootstrap.username}`,
        `  密码：  ${bootstrap.password}`,
        `  （同时写入 ${bootstrap.passwordFile}）`,
        '  请登录后立即修改密码，并删除该文件。',
        '======================================================',
        '',
      ].join('\n'),
    );
  }

  const shutdown = async (signal: string): Promise<void> => {
    app.log.info(`收到 ${signal}，正在关闭服务`);
    stopReplica?.();
    stopMediaWorker?.();
    stopRetention?.();
    await tlsApp?.close();
    await app.close();
    await closePool();
    process.exit(0);
  };
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
}

main().catch((err) => {
  console.error('启动失败：', err);
  process.exit(1);
});
