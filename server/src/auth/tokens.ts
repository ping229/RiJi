/**
 * 令牌：短期访问令牌（JWT，无状态）+ 长期刷新令牌（存库，可撤销）。
 * 全部使用 HS256 与 node:crypto，不引入额外依赖。
 */
import { createHash, randomBytes } from 'node:crypto';
import { SignJWT, jwtVerify } from 'jose';
import { pool } from '../db/pool.ts';
import { config } from '../config.ts';
import { AppError } from '../http/errors.ts';

const secretKey = new TextEncoder().encode(config.jwtSecret);

export type Role = 'user' | 'admin';

export interface AccessClaims {
  userId: string;
  role: Role;
  deviceId: string | null;
}

function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export async function signAccessToken(claims: AccessClaims): Promise<string> {
  return new SignJWT({ role: claims.role, deviceId: claims.deviceId })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(claims.userId)
    .setIssuedAt()
    .setExpirationTime(`${config.accessTokenTtlSeconds}s`)
    .sign(secretKey);
}

export async function verifyAccessToken(token: string): Promise<AccessClaims> {
  try {
    const { payload } = await jwtVerify(token, secretKey, { algorithms: ['HS256'] });
    const userId = payload.sub;
    const role = payload.role;
    const deviceId = payload.deviceId;
    if (typeof userId !== 'string' || (role !== 'user' && role !== 'admin')) {
      throw AppError.unauthorized('令牌内容不完整');
    }
    return {
      userId,
      role,
      deviceId: typeof deviceId === 'string' ? deviceId : null,
    };
  } catch {
    throw AppError.unauthorized();
  }
}

export interface RefreshRotation {
  token: string;
  userId: string;
  deviceId: string | null;
  expiresAt: Date;
}

export async function issueRefreshToken(userId: string, deviceId: string | null): Promise<RefreshRotation> {
  const token = randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + config.refreshTokenTtlSeconds * 1000);
  await pool.query(
    `INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at)
     VALUES ($1, $2, $3, $4)`,
    [userId, deviceId, hashToken(token), expiresAt],
  );
  return { token, userId, deviceId, expiresAt };
}

/** 刷新令牌一次性使用：校验后立即作废旧令牌并发放新的 */
export async function rotateRefreshToken(token: string): Promise<RefreshRotation> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query<{ id: string; user_id: string; device_id: string | null; expires_at: Date; revoked_at: Date | null }>(
      `SELECT id, user_id, device_id, expires_at, revoked_at
         FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE`,
      [hashToken(token)],
    );
    const row = rows[0];
    if (!row || row.revoked_at || new Date(row.expires_at).getTime() < Date.now()) {
      throw AppError.unauthorized('刷新令牌无效或已过期');
    }
    await client.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1', [row.id]);

    const next = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + config.refreshTokenTtlSeconds * 1000);
    await client.query(
      `INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at)
       VALUES ($1, $2, $3, $4)`,
      [row.user_id, row.device_id, hashToken(next), expiresAt],
    );
    await client.query('COMMIT');
    return { token: next, userId: row.user_id, deviceId: row.device_id, expiresAt };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}

export async function revokeRefreshToken(token: string): Promise<void> {
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL', [
    hashToken(token),
  ]);
}

/** 用户被禁用/删除时，一次性吊销其全部刷新令牌 */
export async function revokeAllRefreshTokens(userId: string): Promise<void> {
  await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
}
