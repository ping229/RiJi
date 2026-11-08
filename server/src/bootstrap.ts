/**
 * 首次启动引导：如果库里还没有管理员，就创建一个，并把初始密码写到 var/admin-initial-password.txt。
 * 这样非技术用户不用敲任何命令就能登进后台。
 */
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pool } from './db/pool.ts';
import { hashPassword } from './auth/password.ts';

const ALPHABET = '23456789abcdefghjkmnpqrstuvwxyz';

function generatePassword(length = 16): string {
  const bytes = randomBytes(length);
  let out = '';
  for (let i = 0; i < length; i += 1) out += ALPHABET[bytes[i] % ALPHABET.length];
  return out;
}

export interface BootstrapResult {
  created: boolean;
  username?: string;
  password?: string;
  passwordFile?: string;
}

export async function ensureBootstrapAdmin(log: { info: (msg: string) => void }): Promise<BootstrapResult> {
  // 副本节点不自建管理员：账号统一从主节点复制过来，
  // 否则会出现两个同名但不同 id 的 admin，复制时必然撞唯一约束。
  if (process.env.RJJ_NODE_ROLE === 'replica') {
    return { created: false };
  }

  const { rows } = await pool.query<{ n: number }>("SELECT count(*)::int AS n FROM users WHERE role = 'admin'");
  if ((rows[0]?.n ?? 0) > 0) return { created: false };

  const username = process.env.RJJ_ADMIN_USER?.trim() || 'admin';
  const provided = process.env.RJJ_ADMIN_PASSWORD;
  const password = provided && provided.length >= 8 ? provided : generatePassword();

  const record = await hashPassword(password);
  await pool.query(
    `INSERT INTO users (username, role, status, password_hash, password_salt)
     VALUES ($1, 'admin', 'active', $2, $3)`,
    [username, record.hash, record.salt],
  );

  const dir = path.join(process.cwd(), 'var');
  await mkdir(dir, { recursive: true });
  const passwordFile = path.join(dir, 'admin-initial-password.txt');
  await writeFile(
    passwordFile,
    [
      'RiJi 管理员初始账号',
      `用户名：${username}`,
      `密码：  ${password}`,
      '',
      '请登录管理员后台后立即修改密码，并删除本文件。',
      `生成时间：${new Date().toISOString()}`,
      '',
    ].join('\n'),
    'utf8',
  );

  log.info(`已创建初始管理员 ${username}，密码写入 ${passwordFile}`);
  return { created: true, username, password, passwordFile };
}
