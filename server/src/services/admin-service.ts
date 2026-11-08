/**
 * 管理员业务逻辑。
 *
 * 红线（需求 2.2 / 13.4）：
 *   * 管理员能看到用户数量和状态，但从接口层面拿不到任何日记正文或媒体内容
 *   * 不提供"导出用户日记"的能力
 *   * 删除用户是不可逆操作，必须先禁用再清理
 */
import { promises as fs } from 'node:fs';
import { pool, withTransaction } from '../db/pool.ts';
import { AppError } from '../http/errors.ts';
import { hashPassword } from '../auth/password.ts';
import { revokeAllRefreshTokens } from '../auth/tokens.ts';
import { writeAudit } from './audit.ts';
import { defaultQuotaBytes, formatBytes } from './quota.ts';
import { appendReplicationLog, type UserLogPayload } from './replication.ts';

interface UserRowFull {
  id: string;
  username: string;
  role: string;
  status: string;
  password_hash: string;
  password_salt: string;
  tz_id: string;
  day_cut_hour: number;
  created_at: Date;
  disabled_at: Date | null;
}

function toUserPayload(row: UserRowFull): UserLogPayload {
  return {
    id: row.id,
    username: row.username,
    role: row.role,
    status: row.status,
    passwordHash: row.password_hash,
    passwordSalt: row.password_salt,
    tzId: row.tz_id,
    dayCutHour: row.day_cut_hour,
    createdAt: row.created_at.toISOString(),
    disabledAt: row.disabled_at ? row.disabled_at.toISOString() : null,
  };
}

/** 用户变更也要进复制日志，否则副本上会因为缺少账号而无法落地数据 */
async function logUserChange(
  userId: string,
  op: 'upsert' | 'delete',
  client?: { query: (text: string, values?: unknown[]) => Promise<unknown> },
): Promise<void> {
  const { rows } = await pool.query<UserRowFull>('SELECT * FROM users WHERE id = $1', [userId]);
  const row = rows[0];
  if (!row) return;
  await appendReplicationLog(
    { userId: row.id, entity: 'user', entityId: row.id, op, hlc: '', payload: toUserPayload(row) },
    client,
  );
}

export interface AdminUserRow {
  id: string;
  username: string;
  role: string;
  status: string;
  createdAt: string;
  lastActiveAt: string | null;
  diaryCount: number;
  blockCount: number;
  quotaBytes: number | null;
  usedBytes: number;
  fileCount: number;
}

export async function listUsers(query: string, status: string): Promise<AdminUserRow[]> {
  const { rows } = await pool.query(
    `SELECT u.id, u.username, u.role, u.status, u.created_at, u.last_active_at,
            COALESCE(d.diary_count, 0)::int AS diary_count,
            COALESCE(b.block_count, 0)::int AS block_count,
      u.quota_bytes,
      COALESCE(m.used_bytes, 0)::bigint AS used_bytes,
      COALESCE(m.file_count, 0)::int AS file_count
       FROM users u
       LEFT JOIN (SELECT user_id, count(*) AS diary_count FROM diaries GROUP BY user_id) d ON d.user_id = u.id
       LEFT JOIN (
         SELECT di.user_id, count(bl.id) AS block_count
           FROM blocks bl JOIN diaries di ON di.id = bl.diary_id
          WHERE bl.tombstone = false
          GROUP BY di.user_id
       ) b ON b.user_id = u.id
  LEFT JOIN (
    SELECT user_id, SUM(byte_size) AS used_bytes, count(*) AS file_count
      FROM media GROUP BY user_id
  ) m ON m.user_id = u.id
      WHERE ($1 = '' OR u.username ILIKE '%' || $1 || '%')
        AND ($2 = '' OR u.status = $2)
      ORDER BY u.created_at DESC`,
    [query, status],
  );
  return rows.map((r) => ({
    id: r.id,
    username: r.username,
    role: r.role,
    status: r.status,
    createdAt: new Date(r.created_at).toISOString(),
    lastActiveAt: r.last_active_at ? new Date(r.last_active_at).toISOString() : null,
    diaryCount: r.diary_count,
    blockCount: r.block_count,
    quotaBytes: r.quota_bytes === null || r.quota_bytes === undefined ? null : Number(r.quota_bytes),
    usedBytes: Number(r.used_bytes ?? 0),
    fileCount: Number(r.file_count ?? 0),
  }));
}

export async function createUser(
  actorId: string,
  username: string,
  password: string,
  role: 'user' | 'admin',
  quotaBytes?: number | null,
): Promise<{ id: string; username: string }> {
  const trimmed = username.trim();
  if (!/^[\w\u4e00-\u9fa5.@-]{2,64}$/.test(trimmed)) {
    throw AppError.badRequest('用户名需为 2~64 位字母、数字、下划线、点、@ 或中文');
  }
  const record = await hashPassword(password);
  try {
    const { rows } = await pool.query<{ id: string }>(
      `INSERT INTO users (username, role, status, password_hash, password_salt, quota_bytes)
       VALUES ($1, $2, 'active', $3, $4, $5) RETURNING id`,
      [trimmed, role, record.hash, record.salt, quotaBytes === undefined ? defaultQuotaBytes() : quotaBytes],
    );
    const id = rows[0]!.id;
    await logUserChange(id, 'upsert');
    await writeAudit({ actorId, action: 'user.create', targetType: 'user', targetId: id, detail: { username: trimmed, role } });
    return { id, username: trimmed };
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      throw AppError.conflict('USERNAME_TAKEN', '用户名已存在');
    }
    throw err;
  }
}

/** 调整某用户的存储配额（null = 不限制） */
export async function setUserQuota(
  actorId: string,
  userId: string,
  quotaBytes: number | null,
): Promise<void> {
  if (quotaBytes !== null && (!Number.isFinite(quotaBytes) || quotaBytes < 0)) {
    throw AppError.badRequest('配额必须是不小于 0 的数字（0 或 null 表示不限制）');
  }
  const { rows } = await pool.query<{ username: string }>(
    'SELECT username FROM users WHERE id = $1',
    [userId],
  );
  if (!rows[0]) throw AppError.notFound('用户不存在');
  await pool.query('UPDATE users SET quota_bytes = $2 WHERE id = $1', [userId, quotaBytes]);
  await writeAudit({
    actorId,
    action: 'user.quota.update',
    targetType: 'user',
    targetId: userId,
    detail: {
      username: rows[0].username,
      quotaBytes,
      quotaText: quotaBytes === null ? '不限制' : formatBytes(quotaBytes),
    },
  });
}
export async function setUserStatus(
  actorId: string,
  userId: string,
  status: 'active' | 'disabled',
): Promise<void> {
  const { rows } = await pool.query<{ username: string; role: string }>(
    'SELECT username, role FROM users WHERE id = $1',
    [userId],
  );
  const user = rows[0];
  if (!user) throw AppError.notFound('用户不存在');
  if (user.role === 'admin' && status === 'disabled') {
    const { rows: admins } = await pool.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM users WHERE role = 'admin' AND status = 'active'",
    );
    if ((admins[0]?.n ?? 0) <= 1) {
      throw AppError.conflict('LAST_ADMIN', '不能禁用最后一个管理员账号');
    }
  }
  await pool.query('UPDATE users SET status = $2, disabled_at = CASE WHEN $2 = $3 THEN now() ELSE NULL END WHERE id = $1', [
    userId,
    status,
    'disabled',
  ]);
  if (status === 'disabled') {
    await revokeAllRefreshTokens(userId);
  }
  await logUserChange(userId, 'upsert');
  await writeAudit({
    actorId,
    action: status === 'disabled' ? 'user.disable' : 'user.enable',
    targetType: 'user',
    targetId: userId,
    detail: { username: user.username },
  });
}

/**
 * 删除用户：先冻结、再清理该用户在各节点上的数据与密钥引用。
 * 操作不可逆，调用方必须已完成二次确认。
 */
export async function deleteUser(actorId: string, userId: string, confirmUsername: string): Promise<void> {
  const { rows } = await pool.query<{ username: string }>('SELECT username FROM users WHERE id = $1', [userId]);
  const user = rows[0];
  if (!user) throw AppError.notFound('用户不存在');
  if (user.username !== confirmUsername) {
    throw AppError.badRequest('用户名确认不匹配，删除已取消');
  }

  const mediaRows = await pool.query<{ blob_path: string }>('SELECT blob_path FROM media WHERE user_id = $1', [userId]);

  // 先写"删除用户"的复制日志，再真正删本地行（副本收到后会级联清理）
  await logUserChange(userId, 'delete');

  await withTransaction(async (client) => {
    await client.query("UPDATE users SET status = 'pending_delete' WHERE id = $1", [userId]);
    await client.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
    // 级联删除 diaries / blocks / media / devices
    await client.query('DELETE FROM users WHERE id = $1', [userId]);
  });

  for (const row of mediaRows.rows) {
    await fs.unlink(row.blob_path).catch(() => undefined);
  }

  await writeAudit({
    actorId,
    action: 'user.delete',
    targetType: 'user',
    targetId: userId,
    detail: { username: user.username, mediaRemoved: mediaRows.rows.length },
  });
}

export interface AdminNodeRow {
  id: string;
  role: string;
  status: string;
  endpoint: string | null;
  epoch: number;
  lastHeartbeatAt: string | null;
  createdAt: string;
}

export async function listNodes(): Promise<AdminNodeRow[]> {
  const { rows } = await pool.query(
    `SELECT id, role, status, endpoint, epoch, last_heartbeat_at, created_at,
            replication_cursor, replication_lag, full_sync_requested_at, full_sync_started_at
       FROM nodes ORDER BY created_at ASC`,
  );
  return rows.map((r) => ({
    id: r.id,
    role: r.role,
    status: r.status,
    endpoint: r.endpoint,
    epoch: r.epoch,
    lastHeartbeatAt: r.last_heartbeat_at ? new Date(r.last_heartbeat_at).toISOString() : null,
    createdAt: new Date(r.created_at).toISOString(),
    replicationCursor: Number(r.replication_cursor ?? 0),
    replicationLag: Number(r.replication_lag ?? 0),
    fullSyncRequestedAt: r.full_sync_requested_at ? new Date(r.full_sync_requested_at).toISOString() : null,
    fullSyncStartedAt: r.full_sync_started_at ? new Date(r.full_sync_started_at).toISOString() : null,
  }));
}

export async function addNode(
  actorId: string,
  id: string,
  endpoint: string,
  role: 'primary' | 'replica',
): Promise<AdminNodeRow> {
  if (!/^[a-zA-Z0-9._-]{2,64}$/.test(id)) {
    throw AppError.badRequest('节点标识只能包含字母、数字、点、下划线、短横线');
  }
  try {
    await pool.query(
      `INSERT INTO nodes (id, role, status, endpoint, last_heartbeat_at)
       VALUES ($1, $2, 'syncing', $3, now())`,
      [id, role, endpoint],
    );
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      throw AppError.conflict('NODE_EXISTS', '节点标识已存在');
    }
    throw err;
  }
  await writeAudit({ actorId, action: 'node.add', targetType: 'node', targetId: id, detail: { endpoint, role } });
  const nodes = await listNodes();
  return nodes.find((n) => n.id === id)!;
}

export async function setNodeStatus(
  actorId: string,
  nodeId: string,
  action: 'disable' | 'enable' | 'online',
): Promise<void> {
  const { rows } = await pool.query<{ status: string; role: string }>('SELECT status, role FROM nodes WHERE id = $1', [
    nodeId,
  ]);
  const node = rows[0];
  if (!node) throw AppError.notFound('节点不存在');

  const next = action === 'disable' ? 'disabled' : action === 'enable' ? 'syncing' : 'online';
  if (action === 'disable' && node.role === 'primary') {
    const { rows: others } = await pool.query<{ n: number }>(
      "SELECT count(*)::int AS n FROM nodes WHERE id <> $1 AND status IN ('online','syncing')",
      [nodeId],
    );
    if ((others[0]?.n ?? 0) === 0) {
      throw AppError.conflict('LAST_PRIMARY', '这是唯一可用的主节点，禁用后集群将无法写入');
    }
  }

  await pool.query('UPDATE nodes SET status = $2, last_heartbeat_at = now() WHERE id = $1', [nodeId, next]);
  await writeAudit({ actorId, action: `node.${action}`, targetType: 'node', targetId: nodeId, detail: { from: node.status, to: next } });
}

/**
 * 删除节点（安全退役，需求 2.2 / 10.6.5）：
 * 必须先确认数据在其他节点有完整副本，否则阻止。
 */
export async function retireNode(actorId: string, nodeId: string): Promise<{ retired: boolean; remaining: number }> {
  const { rows } = await pool.query<{ status: string; role: string }>('SELECT status, role FROM nodes WHERE id = $1', [
    nodeId,
  ]);
  const node = rows[0];
  if (!node) throw AppError.notFound('节点不存在');

  const { rows: healthy } = await pool.query<{ id: string }>(
    "SELECT id FROM nodes WHERE id <> $1 AND status IN ('online','syncing')",
    [nodeId],
  );
  if (healthy.length === 0) {
    throw AppError.conflict('UNIQUE_COPY', '该节点是唯一持有全量数据的节点，删除会导致数据丢失，已阻止');
  }
  if (node.role === 'primary') {
    const { rows: replicas } = await pool.query<{ id: string }>(
      "SELECT id FROM nodes WHERE id <> $1 AND role = 'replica' AND status IN ('online','syncing')",
      [nodeId],
    );
    if (replicas.length === 0) {
      throw AppError.conflict('NEED_PROMOTE', '该节点是主节点，请先把一个副本提升为主节点再退役');
    }
  }

  await pool.query("UPDATE nodes SET status = 'retiring' WHERE id = $1", [nodeId]);
  await writeAudit({
    actorId,
    action: 'node.retire.request',
    targetType: 'node',
    targetId: nodeId,
    detail: { remaining: healthy.length },
  });
  return { retired: true, remaining: healthy.length };
}

/** 最终下线：退役中的节点确认移除 */
export async function finalizeRetire(actorId: string, nodeId: string): Promise<void> {
  const { rows } = await pool.query<{ status: string }>('SELECT status FROM nodes WHERE id = $1', [nodeId]);
  const node = rows[0];
  if (!node) throw AppError.notFound('节点不存在');
  if (node.status !== 'retiring') {
    throw AppError.badRequest('只有“退役中”的节点才能执行最终下线');
  }
  await pool.query("UPDATE nodes SET status = 'retired', last_heartbeat_at = now() WHERE id = $1", [nodeId]);
  await writeAudit({ actorId, action: 'node.retire.finalize', targetType: 'node', targetId: nodeId });
}

export async function promoteNode(actorId: string, nodeId: string): Promise<void> {
  const { rows } = await pool.query<{ status: string; role: string }>('SELECT status, role FROM nodes WHERE id = $1', [
    nodeId,
  ]);
  const node = rows[0];
  if (!node) throw AppError.notFound('节点不存在');
  if (node.status === 'retired' || node.status === 'disabled') {
    throw AppError.badRequest('已退役或已禁用的节点不能提升为主节点');
  }

  await withTransaction(async (client) => {
    const { rows: epochRow } = await client.query<{ epoch: number }>('SELECT COALESCE(MAX(epoch), 1) AS epoch FROM nodes');
    const nextEpoch = Number(epochRow[0]?.epoch ?? 1) + 1;
    // 先降级原主节点，再升级新主节点：顺序不能反，否则会出现两个主节点
    await client.query("UPDATE nodes SET role = 'replica' WHERE role = 'primary' AND id <> $1", [nodeId]);
    await client.query("UPDATE nodes SET role = 'primary', status = 'online', epoch = $2 WHERE id = $1", [
      nodeId,
      nextEpoch,
    ]);
  });

  await writeAudit({ actorId, action: 'node.promote', targetType: 'node', targetId: nodeId });
}

/**
 * 请求某个节点做一次全量同步（需求 7.2.1）。
 * 只记标记，真正的重置由副本在自己下一次心跳里执行——主节点不能直接改副本的库。
 */
export async function requestFullSync(actorId: string, nodeId: string): Promise<void> {
  const { rows } = await pool.query<{ status: string }>('SELECT status FROM nodes WHERE id = $1', [nodeId]);
  const node = rows[0];
  if (!node) throw AppError.notFound('节点不存在');
  if (node.status === 'retired' || node.status === 'disabled') {
    throw AppError.badRequest('已退役或已禁用的节点不能发起全量同步');
  }
  await pool.query(
    "UPDATE nodes SET full_sync_requested_at = now(), status = 'syncing' WHERE id = $1",
    [nodeId],
  );
  await writeAudit({
    actorId,
    action: 'node.fullsync.request',
    targetType: 'node',
    targetId: nodeId,
    detail: {},
  });
}

export interface ClusterStats {
  users: number;
  usersDisabled: number;
  diaries: number;
  blocks: number;
  mediaCount: number;
  mediaBytes: number;
  nodes: number;
  nodesOnline: number;
  auditEntries: number;
}

export async function clusterStats(): Promise<ClusterStats> {
  const [users, disabled, diaries, blocks, media, nodes, online, audit] = await Promise.all([
    pool.query<{ n: number }>('SELECT count(*)::int AS n FROM users'),
    pool.query<{ n: number }>("SELECT count(*)::int AS n FROM users WHERE status <> 'active'"),
    pool.query<{ n: number }>('SELECT count(*)::int AS n FROM diaries'),
    pool.query<{ n: number }>('SELECT count(*)::int AS n FROM blocks WHERE tombstone = false'),
    pool.query<{ n: number; bytes: string | null }>('SELECT count(*)::int AS n, COALESCE(SUM(byte_size), 0)::text AS bytes FROM media'),
    pool.query<{ n: number }>('SELECT count(*)::int AS n FROM nodes'),
    pool.query<{ n: number }>("SELECT count(*)::int AS n FROM nodes WHERE status IN ('online','syncing')"),
    pool.query<{ n: number }>('SELECT count(*)::int AS n FROM audit_log'),
  ]);

  return {
    users: users.rows[0]?.n ?? 0,
    usersDisabled: disabled.rows[0]?.n ?? 0,
    diaries: diaries.rows[0]?.n ?? 0,
    blocks: blocks.rows[0]?.n ?? 0,
    mediaCount: media.rows[0]?.n ?? 0,
    mediaBytes: Number(media.rows[0]?.bytes ?? 0),
    nodes: nodes.rows[0]?.n ?? 0,
    nodesOnline: online.rows[0]?.n ?? 0,
    auditEntries: audit.rows[0]?.n ?? 0,
  };
}

/**
 * 一致性校验（单节点版本）：统计各用户的数据摘要，供后续多节点比对复用。
 * 只输出数量与哈希，不输出任何内容。
 */
export async function consistencySummary(): Promise<{
  nodeId: string;
  users: number;
  diaries: number;
  blocks: number;
  media: number;
  digest: string;
  checkedAt: string;
}> {
  const { rows } = await pool.query<{ digest: string | null }>(
    `SELECT md5(string_agg(id::text || ':' || updated_at::text, ',' ORDER BY id)) AS digest FROM blocks`,
  );
  const stats = await clusterStats();
  const { rows: nodeRows } = await pool.query<{ id: string }>("SELECT id FROM nodes WHERE role = 'primary' LIMIT 1");
  return {
    nodeId: nodeRows[0]?.id ?? 'unknown',
    users: stats.users,
    diaries: stats.diaries,
    blocks: stats.blocks,
    media: stats.mediaCount,
    digest: rows[0]?.digest ?? 'empty',
    checkedAt: new Date().toISOString(),
  };
}
