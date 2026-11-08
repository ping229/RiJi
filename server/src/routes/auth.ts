/**
 * 认证与设备接口。
 * 登录返回：短期访问令牌 + 长期刷新令牌 + 用户信息 + 设备 ID。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { hashPassword, verifyPassword } from '../auth/password.ts';
import {
  issueRefreshToken,
  revokeAllRefreshTokens,
  revokeRefreshToken,
  rotateRefreshToken,
  signAccessToken,
  type Role,
} from '../auth/tokens.ts';
import { AppError } from '../http/errors.ts';
import { currentUserId, requireAuth } from '../http/auth-guard.ts';
import { writeAudit } from '../services/audit.ts';

const loginSchema = z.object({
  username: z.string().min(1).max(64),
  password: z.string().min(1).max(256),
  device: z
    .object({
      name: z.string().min(1).max(64),
      platform: z.enum(['windows', 'android', 'macos', 'linux', 'unknown']).default('unknown'),
    })
    .optional(),
});

const refreshSchema = z.object({ refreshToken: z.string().min(10) });
const deviceSchema = z.object({
  name: z.string().min(1).max(64),
  platform: z.enum(['windows', 'android', 'macos', 'linux', 'unknown']).default('unknown'),
});

interface UserRow {
  id: string;
  username: string;
  role: Role;
  status: string;
  password_hash: string;
  password_salt: string;
  tz_id: string;
  day_cut_hour: number;
  kdf_salt: string | null;
  kdf_iterations: number;
  key_wrap: string | null;
  key_wrap_nonce: string | null;
}

async function upsertDevice(userId: string, name: string, platform: string): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    `INSERT INTO devices (user_id, name, platform, last_seen_at)
     VALUES ($1, $2, $3, now())
     RETURNING id`,
    [userId, name, platform],
  );
  const id = rows[0]?.id;
  if (!id) throw AppError.internal('设备注册失败');
  return id;
}

export async function registerAuthRoutes(app: FastifyInstance): Promise<void> {
  app.post('/api/auth/login', async (req) => {
    const body = loginSchema.parse(req.body);
    const { rows } = await pool.query<UserRow>('SELECT * FROM users WHERE username = $1', [body.username]);
    const user = rows[0];
    // 用户不存在与密码错误返回同一提示，避免用户名枚举
    if (!user) throw new AppError('INVALID_CREDENTIALS', 401, '用户名或密码错误');
    if (user.status === 'disabled') throw new AppError('ACCOUNT_DISABLED', 403, '账号已被禁用，请联系管理员');
    if (user.status === 'pending_delete') throw new AppError('ACCOUNT_DELETING', 403, '账号正在注销中');

    const ok = await verifyPassword(body.password, { hash: user.password_hash, salt: user.password_salt });
    if (!ok) throw new AppError('INVALID_CREDENTIALS', 401, '用户名或密码错误');

    const deviceId = body.device ? await upsertDevice(user.id, body.device.name, body.device.platform) : null;
    const accessToken = await signAccessToken({ userId: user.id, role: user.role, deviceId });
    const refresh = await issueRefreshToken(user.id, deviceId);
    await pool.query('UPDATE users SET last_active_at = now() WHERE id = $1', [user.id]);

    return {
      accessToken,
      refreshToken: refresh.token,
      expiresIn: 12 * 60 * 60,
      deviceId,
      user: {
        id: user.id,
        username: user.username,
        role: user.role,
        tzId: user.tz_id,
        dayCutHour: user.day_cut_hour,
        kdfSalt: user.kdf_salt,
        kdfIterations: user.kdf_iterations,
        keyWrap: user.key_wrap,
        keyWrapNonce: user.key_wrap_nonce,
      },
    };
  });

  /**
   * 修改密码。
   * 关键点：改密码只换「包裹主密钥的 KEK」，主密钥本身不变，
   * 因此历史日记不需要重新加密，也不会变得无法解密。
   * 调用方必须先解开旧主密钥、再用新密码派生的 KEK 重新包裹后提交。
   */
  app.post('/api/auth/change-password', { preHandler: requireAuth }, async (req) => {
    const body = z
      .object({
        currentPassword: z.string().min(1).max(256),
        newPassword: z.string().min(8).max(256),
        keyWrap: z.string().min(16),
        keyWrapNonce: z.string().min(8),
      })
      .parse(req.body);

    const userId = currentUserId(req);
    const { rows } = await pool.query<{ password_hash: string; password_salt: string; username: string }>(
      'SELECT password_hash, password_salt, username FROM users WHERE id = $1',
      [userId],
    );
    const user = rows[0];
    if (!user) throw AppError.unauthorized('账号已不存在');

    const ok = await verifyPassword(body.currentPassword, {
      hash: user.password_hash,
      salt: user.password_salt,
    });
    if (!ok) throw new AppError('WRONG_PASSWORD', 400, '当前密码不正确');

    const record = await hashPassword(body.newPassword);
    await pool.query(
      'UPDATE users SET password_hash = $2, password_salt = $3, key_wrap = $4, key_wrap_nonce = $5 WHERE id = $1',
      [userId, record.hash, record.salt, body.keyWrap, body.keyWrapNonce],
    );
    // 其他设备上的登录态全部作废，避免旧密码会话继续可用
    await revokeAllRefreshTokens(userId);

    await writeAudit({
      actorId: userId,
      action: 'user.password.change',
      targetType: 'user',
      targetId: userId,
      detail: { username: user.username },
    });
    return { ok: true };
  });

  app.post('/api/auth/refresh', async (req) => {
    const body = refreshSchema.parse(req.body);
    const rotated = await rotateRefreshToken(body.refreshToken);
    const { rows } = await pool.query<{ role: Role; status: string }>('SELECT role, status FROM users WHERE id = $1', [
      rotated.userId,
    ]);
    const user = rows[0];
    if (!user || user.status !== 'active') {
      throw AppError.forbidden('账号状态异常，请重新登录');
    }
    const accessToken = await signAccessToken({ userId: rotated.userId, role: user.role, deviceId: rotated.deviceId });
    return { accessToken, refreshToken: rotated.token };
  });

  app.post('/api/auth/logout', async (req) => {
    const body = refreshSchema.parse(req.body);
    await revokeRefreshToken(body.refreshToken);
    return { ok: true };
  });

  app.get('/api/auth/me', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const { rows } = await pool.query(
      `SELECT id, username, role, tz_id, day_cut_hour, created_at, last_active_at
         FROM users WHERE id = $1`,
      [userId],
    );
    const user = rows[0];
    if (!user) throw AppError.unauthorized('账号已不存在');
    return { user, deviceId: req.auth?.deviceId ?? null };
  });

  /**
   * 首次启用端到端加密时，客户端生成随机盐并提交到这里。
   * 盐不是秘密；服务端存它只是为了让同一账号在任何设备上派生出同一把密钥。
   */
  /**
   * 主密钥包裹体的存取。
   * 服务端只存"用密码派生的 KEK 加密后的主密钥"，
   * 没有 KEK 就解不开，因此管理员依然读不到明文。
   */
  app.get('/api/auth/key-wrap', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const { rows } = await pool.query<{ key_wrap: string | null; key_wrap_nonce: string | null }>(
      'SELECT key_wrap, key_wrap_nonce FROM users WHERE id = $1',
      [userId],
    );
    const row = rows[0];
    return { wrap: row?.key_wrap ?? null, nonce: row?.key_wrap_nonce ?? null };
  });

  app.put('/api/auth/key-wrap', { preHandler: requireAuth }, async (req) => {
    const body = z
      .object({ wrap: z.string().min(16), nonce: z.string().min(8) })
      .parse(req.body);
    const userId = currentUserId(req);
    // 覆盖是允许的：改密码时用新 KEK 重新包裹同一把主密钥
    await pool.query('UPDATE users SET key_wrap = $2, key_wrap_nonce = $3 WHERE id = $1', [
      userId,
      body.wrap,
      body.nonce,
    ]);
    return { ok: true };
  });

  app.post('/api/auth/kdf-salt', { preHandler: requireAuth }, async (req) => {
    const body = z
      .object({ salt: z.string().min(16).max(128), iterations: z.number().int().min(100000).max(1000000) })
      .parse(req.body);
    const userId = currentUserId(req);
    const { rows } = await pool.query<{ kdf_salt: string | null }>('SELECT kdf_salt FROM users WHERE id = $1', [userId]);
    if (rows[0]?.kdf_salt) {
      throw AppError.conflict('KDF_SALT_EXISTS', '该账号已经启用加密，盐不可覆盖');
    }
    await pool.query('UPDATE users SET kdf_salt = $2, kdf_iterations = $3 WHERE id = $1', [userId, body.salt, body.iterations]);
    return { ok: true };
  });

  app.post('/api/devices', { preHandler: requireAuth }, async (req) => {
    const body = deviceSchema.parse(req.body);
    const userId = currentUserId(req);
    const deviceId = await upsertDevice(userId, body.name, body.platform);
    return { deviceId };
  });
}
