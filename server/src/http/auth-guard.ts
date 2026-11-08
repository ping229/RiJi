/**
 * 鉴权中间件。
 * 所有普通用户接口都必须经过这里，并把 userId 注入到 request.auth，
 * 后续 SQL 一律带 user_id 过滤（需求 6.2 的数据隔离在接口层强制）。
 */
import type { FastifyRequest, FastifyReply } from 'fastify';
import { verifyAccessToken, type AccessClaims } from '../auth/tokens.ts';
import { AppError } from './errors.ts';

declare module 'fastify' {
  interface FastifyRequest {
    auth?: AccessClaims;
  }
}

function extractBearer(req: FastifyRequest): string | null {
  const header = req.headers.authorization;
  if (!header) return null;
  const [scheme, token] = header.split(' ');
  if (!scheme || scheme.toLowerCase() !== 'bearer' || !token) return null;
  return token.trim();
}

export async function requireAuth(req: FastifyRequest, _reply: FastifyReply): Promise<void> {
  const token = extractBearer(req);
  if (!token) throw AppError.unauthorized();
  req.auth = await verifyAccessToken(token);
}

export async function requireAdmin(req: FastifyRequest, _reply: FastifyReply): Promise<void> {
  await requireAuth(req, _reply);
  if (req.auth?.role !== 'admin') throw AppError.forbidden('该接口仅管理员可访问');
}

/** 从请求里取出当前用户 ID；没经过 requireAuth 就是编码错误 */
export function currentUserId(req: FastifyRequest): string {
  const id = req.auth?.userId;
  if (!id) throw AppError.unauthorized();
  return id;
}

export function currentDeviceId(req: FastifyRequest): string | null {
  return req.auth?.deviceId ?? null;
}
