/**
 * 运维脚本：重置某个账号的密码。
 *
 * 用法：
 *   npm run set-password -- <用户名> <新密码>
 *
 * 为什么需要它：管理员密码遗忘是部署文档必须覆盖的故障场景之一（需求 12.1）。
 * 该操作不需要旧密码，但必须在服务器本机执行，并会写入审计日志。
 */
import { pool, closePool } from '../src/db/pool.ts';
import { hashPassword } from '../src/auth/password.ts';
import { writeAudit } from '../src/services/audit.ts';
import { appendReplicationLog } from '../src/services/replication.ts';

async function main(): Promise<void> {
  const [username, password] = process.argv.slice(2);
  if (!username || !password) {
    console.error('用法：npm run set-password -- <用户名> <新密码>');
    process.exit(2);
  }
  if (password.length < 8) {
    console.error('密码至少 8 位');
    process.exit(2);
  }

  const { rows } = await pool.query<{ id: string; username: string }>(
    'SELECT id, username FROM users WHERE username = $1',
    [username],
  );
  const user = rows[0];
  if (!user) {
    console.error(`用户不存在：${username}`);
    process.exit(3);
  }

  // 已启用端到端加密的账号，密码同时是解开主密钥的 KEK 的一部分。
  // 直接改哈希会让历史数据永久无法解密，必须走客户端里"改密码 → 重新包裹"的流程。
  const { rows: wrapRows } = await pool.query<{ key_wrap: string | null }>(
    'SELECT key_wrap FROM users WHERE id = $1',
    [user.id],
  );
  if (wrapRows[0]?.key_wrap) {
    console.error('✗ 该账号已启用端到端加密，直接重置密码会导致历史日记永久无法解密。');
    console.error('  请使用客户端内的改密码功能（会重新包裹主密钥）。');
    console.error('  如果你确认要放弃历史数据：先清空该账号的 key_wrap 字段，再执行本命令。');
    process.exit(4);
  }

  const record = await hashPassword(password);
  await pool.query('UPDATE users SET password_hash = $2, password_salt = $3, status = $4 WHERE id = $1', [
    user.id,
    record.hash,
    record.salt,
    'active',
  ]);
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [user.id]);

  // 让副本也拿到新密码
  const { rows: full } = await pool.query('SELECT * FROM users WHERE id = $1', [user.id]);
  const row = full[0]!;
  await appendReplicationLog({
    userId: row.id,
    entity: 'user',
    entityId: row.id,
    op: 'upsert',
    hlc: '',
    payload: {
      id: row.id,
      username: row.username,
      role: row.role,
      status: row.status,
      passwordHash: row.password_hash,
      passwordSalt: row.password_salt,
      tzId: row.tz_id,
      dayCutHour: row.day_cut_hour,
      createdAt: new Date(row.created_at).toISOString(),
      disabledAt: row.disabled_at ? new Date(row.disabled_at).toISOString() : null,
    },
  });

  await writeAudit({
    actorId: null,
    action: 'user.password.reset',
    targetType: 'user',
    targetId: user.id,
    detail: { username: user.username, via: 'cli' },
  });

  console.log(`已重置 ${user.username} 的密码，并吊销其全部登录令牌`);
}

main()
  .then(() => closePool())
  .then(() => process.exit(0))
  .catch(async (err) => {
    console.error(err);
    await closePool();
    process.exit(1);
  });
