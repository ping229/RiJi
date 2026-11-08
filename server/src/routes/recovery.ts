/**
 * 恢复短语与"忘记密码"恢复流程。
 *
 * 安全设计：
 *   * 恢复密钥由短语派生，服务端只存「用恢复密钥包裹的主密钥」+「恢复密钥的散列」
 *   * 恢复时客户端出示散列值作为持有证明，服务端比对后才允许改密码
 *   * 整个流程服务端拿不到主密钥，也拿不到恢复密钥
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { AppError } from '../http/errors.ts';
import { hashPassword } from '../auth/password.ts';
import { currentUserId, requireAuth } from '../http/auth-guard.ts';
import { revokeAllRefreshTokens } from '../auth/tokens.ts';
import { writeAudit } from '../services/audit.ts';
import { appendReplicationLog, toUserLogPayload } from '../services/replication.ts';

const putSchema = z.object({
  wrap: z.string().min(16),
  nonce: z.string().min(8),
  proof: z.string().min(32).max(128),
});

const startSchema = z.object({ username: z.string().min(1).max(64) });
const completeSchema = z.object({
  username: z.string().min(1).max(64),
  proof: z.string().min(32).max(128),
  newPassword: z.string().min(8).max(256),
  keyWrap: z.string().min(16),
  keyWrapNonce: z.string().min(8),
});

export async function registerRecoveryRoutes(app: FastifyInstance): Promise<void> {
  /** 已登录用户：查看 / 设置恢复短语的包裹体 */
  app.get('/api/auth/recovery-wrap', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const { rows } = await pool.query<{ recovery_wrap: string | null }>(
      'SELECT recovery_wrap FROM users WHERE id = $1',
      [userId],
    );
    return { hasRecovery: Boolean(rows[0]?.recovery_wrap) };
  });

  app.put('/api/auth/recovery-wrap', { preHandler: requireAuth }, async (req) => {
    const body = putSchema.parse(req.body);
    const userId = currentUserId(req);
    await pool.query(
      `UPDATE users SET recovery_wrap = $2, recovery_nonce = $3, recovery_proof = $4,
              recovery_created_at = now() WHERE id = $1`,
      [userId, body.wrap, body.nonce, body.proof],
    );
    await writeAudit({
      actorId: userId,
      action: 'user.recovery.set',
      targetType: 'user',
      targetId: userId,
      detail: {},
    });
    return { ok: true };
  });

  /**
   * 未登录：拿到恢复所需的最小信息。
   * 返回的盐与包裹体都是密文性质，泄漏也无法推导出主密钥。
   */
  app.post('/api/auth/recover/start', async (req) => {
    const body = startSchema.parse(req.body);
    const { rows } = await pool.query<{
      kdf_salt: string | null;
      kdf_iterations: number;
      recovery_wrap: string | null;
      recovery_nonce: string | null;
    }>(
      'SELECT kdf_salt, kdf_iterations, recovery_wrap, recovery_nonce FROM users WHERE username = $1',
      [body.username],
    );
    const row = rows[0];
    if (!row || !row.recovery_wrap || !row.recovery_nonce) {
      throw AppError.notFound('该账号没有设置恢复短语，无法用短语恢复');
    }
    return {
      kdfSalt: row.kdf_salt,
      kdfIterations: row.kdf_iterations,
      recoveryWrap: row.recovery_wrap,
      recoveryNonce: row.recovery_nonce,
    };
  });

  /** 未登录：用恢复短语证明身份，然后设置新密码 + 新包裹体 */
  app.post('/api/auth/recover/complete', async (req) => {
    const body = completeSchema.parse(req.body);
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query<{
        id: string;
        kdf_salt: string | null;
        kdf_iterations: number;
        recovery_proof: string | null;
      }>(
        'SELECT id, kdf_salt, kdf_iterations, recovery_proof FROM users WHERE username = $1 FOR UPDATE',
        [body.username],
      );
      const user = rows[0];
      if (!user || !user.recovery_proof) {
        throw AppError.notFound('该账号没有设置恢复短语');
      }
      // 定长比较，避免通过响应时间猜测散列
      const expected = Buffer.from(user.recovery_proof, 'utf8');
      const actual = Buffer.from(body.proof, 'utf8');
      if (expected.length !== actual.length || !cryptoEqual(expected, actual)) {
        throw AppError.forbidden('恢复短语不正确');
      }

      // 盐可以沿用：新密码 + 同一个盐派生出新 KEK，用来包裹同一把主密钥
      if (!user.kdf_salt) {
        const salt = Buffer.from(body.keyWrapNonce, 'base64').toString('base64').slice(0, 22);
        await client.query('UPDATE users SET kdf_salt = $2 WHERE id = $1', [user.id, salt]);
      }
      const record = await hashPassword(body.newPassword);
      await client.query(
        `UPDATE users SET password_hash = $2, password_salt = $3,
                key_wrap = $4, key_wrap_nonce = $5, status = 'active', disabled_at = NULL
          WHERE id = $1`,
        [user.id, record.hash, record.salt, body.keyWrap, body.keyWrapNonce],
      );
      await client.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [
        user.id,
      ]);
      await client.query('COMMIT');

      await writeAudit({
        actorId: null,
        action: 'user.recovery.restore',
        targetType: 'user',
        targetId: user.id,
        detail: { via: 'recovery-phrase' },
      });

      // 让副本也拿到更新后的账号（含新的包裹体）
      const { rows: full } = await pool.query('SELECT * FROM users WHERE id = $1', [user.id]);
      const row = full[0];
      if (row) {
        await appendReplicationLog({
          userId: row.id,
          entity: 'user',
          entityId: row.id,
          op: 'upsert',
          hlc: '',
          payload: toUserLogPayload(row),
        });
      }
      await revokeAllRefreshTokens(user.id);
      return { ok: true };
    } catch (err) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw err;
    } finally {
      client.release();
    }
  });
}

/** 定长逐字节比较，避免短路比较带来的时序泄漏 */
function cryptoEqual(a: Buffer, b: Buffer): boolean {
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}
