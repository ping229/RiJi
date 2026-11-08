/**
 * 运维脚本：在"不丢历史数据"的前提下轮换密码（适用于已启用端到端加密的账号）。
 *
 * 为什么需要它：`set-password.ts` 遇到有 `key_wrap` 的账号会拒绝执行，
 * 因为直接换 hash 会让主密钥再也解不开。这个脚本按客户端"修改密码"的
 * 同一套算法重包裹主密钥，所以历史日记/媒体仍然可读。
 *
 * 原理：
 *   旧密码 → PBKDF2(salt) → 旧 KEK → 解开 key_wrap → 主密钥 M
 *   新密码 → PBKDF2(同一 salt) → 新 KEK → 重新包裹 M → 写回 key_wrap
 *
 * 用法（在服务器上，需要 RJJ_DATABASE_URL；口令用 base64 传，避免 shell 吃字符）：
 *   OLD=$(printf '%s' '旧密码' | base64 -w0)
 *   NEW=$(printf '%s' '新密码' | base64 -w0)
 *   RJJ_OLD_PASS_B64=$OLD RJJ_NEW_PASS_B64=$NEW node scripts/rewrap-password.mjs admin
 *
 * 执行前请先备份该用户行（password_hash/password_salt/kdf_salt/key_wrap/key_wrap_nonce），
 * 脚本只在自检通过后才写库。
 */
import { pbkdf2Sync, randomBytes, createCipheriv, createDecipheriv, scrypt as scryptCb } from 'node:crypto';
import { promisify } from 'node:util';
import pg from 'pg';

const scrypt = promisify(scryptCb);
const [, , username] = process.argv;
// 口令走 base64 环境变量：避免 shell 把 ! $ * 之类的字符吃掉
const oldPass = process.env.RJJ_OLD_PASS_B64
  ? Buffer.from(process.env.RJJ_OLD_PASS_B64, 'base64').toString('utf8')
  : '';
const newPass = process.env.RJJ_NEW_PASS_B64
  ? Buffer.from(process.env.RJJ_NEW_PASS_B64, 'base64').toString('utf8')
  : '';

if (!username || !oldPass || !newPass || newPass.length < 12) {
  console.error('用法：RJJ_OLD_PASS_B64=... RJJ_NEW_PASS_B64=... node scripts/rewrap-password.mjs <用户名>');
  process.exit(2);
}

const AAD = Buffer.from('riji-key-wrap-v1');

function openWrap(kek, cipher, nonce) {
  const d = createDecipheriv('aes-256-gcm', kek, nonce);
  d.setAAD(AAD);
  d.setAuthTag(cipher.subarray(cipher.length - 16));
  return Buffer.concat([d.update(cipher.subarray(0, cipher.length - 16)), d.final()]);
}

function sealWrap(kek, plain) {
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', kek, nonce);
  c.setAAD(AAD);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  return { cipher: Buffer.concat([ct, c.getAuthTag()]), nonce };
}

const client = new pg.Client({ connectionString: process.env.RJJ_DATABASE_URL });
await client.connect();
try {
  const { rows } = await client.query(
    'SELECT id, kdf_salt, kdf_iterations, key_wrap, key_wrap_nonce FROM users WHERE username = $1',
    [username],
  );
  const u = rows[0];
  if (!u) throw new Error('用户不存在');
  if (!u.key_wrap || !u.kdf_salt) throw new Error('该账号没有包裹体，请改用 set-password');

  const salt = Buffer.from(u.kdf_salt, 'base64');
  const iterations = u.kdf_iterations ?? 210000;
  const wrap = Buffer.from(u.key_wrap, 'base64');
  const nonce = Buffer.from(u.key_wrap_nonce, 'base64');

  const kekOld = pbkdf2Sync(oldPass, salt, iterations, 32, 'sha256');
  const master = openWrap(kekOld, wrap, nonce);
  if (master.length !== 32) throw new Error(`主密钥长度异常：${master.length}`);

  const kekNew = pbkdf2Sync(newPass, salt, iterations, 32, 'sha256');
  const sealed = sealWrap(kekNew, master);
  // 自检：新包裹体必须能解回同一把主密钥
  if (!openWrap(kekNew, sealed.cipher, sealed.nonce).equals(master)) {
    throw new Error('自检失败：新包裹体解不回主密钥');
  }

  const hashSalt = randomBytes(16).toString('base64');
  const hash = (await scrypt(newPass, hashSalt, 64)).toString('base64');

  await client.query('BEGIN');
  await client.query(
    `UPDATE users SET password_hash = $2, password_salt = $3, key_wrap = $4, key_wrap_nonce = $5
      WHERE id = $1`,
    [u.id, hash, hashSalt, sealed.cipher.toString('base64'), sealed.nonce.toString('base64')],
  );
  await client.query(
    'UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL',
    [u.id],
  );
  await client.query('COMMIT');
  console.log(`REWRAP_OK user=${username} master_bytes=${master.length}`);
} catch (err) {
  console.error(`FAILED: ${err.message}`);
  process.exitCode = 1;
} finally {
  await client.end();
}
