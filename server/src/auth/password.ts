/**
 * 密码哈希：scrypt（Node 内置，无原生依赖）。
 * 存储形式：salt + hash 分列存放，比较用定长时间比较防止计时攻击。
 */
import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const scrypt = promisify(scryptCallback) as (
  password: string | Buffer,
  salt: string | Buffer,
  keylen: number,
) => Promise<Buffer>;

const KEY_LENGTH = 64;
const MIN_PASSWORD_LENGTH = 8;

export interface PasswordRecord {
  hash: string;
  salt: string;
}

export function assertPasswordStrength(password: string): void {
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new Error(`密码至少需要 ${MIN_PASSWORD_LENGTH} 位`);
  }
}

export async function hashPassword(password: string): Promise<PasswordRecord> {
  assertPasswordStrength(password);
  const salt = randomBytes(16).toString('base64');
  const key = await scrypt(password, salt, KEY_LENGTH);
  return { hash: key.toString('base64'), salt };
}

export async function verifyPassword(password: string, record: PasswordRecord): Promise<boolean> {
  const expected = Buffer.from(record.hash, 'base64');
  const actual = await scrypt(password, record.salt, KEY_LENGTH);
  if (expected.length !== actual.length) return false;
  return timingSafeEqual(expected, actual);
}
