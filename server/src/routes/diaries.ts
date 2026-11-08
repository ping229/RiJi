/**
 * 日记接口：日历窗口、日记列表、单篇读取、块批量写入、删除块、版本历史。
 */
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { config } from '../config.ts';
import { today, writableDates, isValidIsoDate, addDays } from '../domain/calendar.ts';
import { AppError } from '../http/errors.ts';
import { currentUserId, requireAuth } from '../http/auth-guard.ts';
import {
  applyBatch,
  getDiary,
  listBlockVersions,
  listDiaries,
  tombstoneBlock,
  type BlockInput,
  type BlockType,
} from '../services/diary-service.ts';

const blockSchema = z.object({
  blockId: z.string().uuid(),
  blockType: z.enum(['text', 'image', 'audio', 'video', 'divider']),
  orderKey: z.string().min(1).max(64),
  vv: z.record(z.string(), z.number().int().nonnegative()),
  hlc: z.string().min(5).max(64),
  payload: z.string(), // base64
  mediaRef: z.string().max(128).nullish(),
  enc: z.enum(['none', 'aes-256-gcm']).default('none'),
  nonce: z.string().nullish(),
  keyId: z.string().max(64).nullish(),
});

const batchSchema = z.object({
  tzId: z.string().min(1).max(64),
  clientNow: z.string().datetime(),
  deviceId: z.string().uuid().nullish(),
  operations: z.array(blockSchema).max(500),
});

const dateParam = z.string().refine(isValidIsoDate, { message: '日期格式应为 YYYY-MM-DD' });

interface UserSettings {
  tz_id: string;
  day_cut_hour: number;
}

async function loadSettings(userId: string): Promise<UserSettings> {
  const { rows } = await pool.query<UserSettings>('SELECT tz_id, day_cut_hour FROM users WHERE id = $1', [userId]);
  const row = rows[0];
  if (!row) throw AppError.unauthorized('账号已不存在');
  return row;
}

export async function registerDiaryRoutes(app: FastifyInstance): Promise<void> {
  // 日历窗口：客户端据此渲染"哪些天可写"
  app.get('/api/calendar', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const settings = await loadSettings(userId);
    const now = new Date();
    return {
      tzId: settings.tz_id,
      dayCutHour: settings.day_cut_hour,
      windowDays: config.writeWindowDays,
      today: today(now, settings.tz_id, settings.day_cut_hour),
      // 界面画几天、服务端就允许几天：两边必须是同一个 windowDays
      writableDates: writableDates(now, settings.tz_id, {
        cutHour: settings.day_cut_hour,
        windowDays: config.writeWindowDays,
      }),
      serverNow: now.toISOString(),
    };
  });

  app.get('/api/diaries', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const q = z
      .object({ from: z.string().optional(), to: z.string().optional() })
      .parse(req.query);
    const settings = await loadSettings(userId);
    const todayIso = today(new Date(), settings.tz_id, settings.day_cut_hour);
    const to = q.to && isValidIsoDate(q.to) ? q.to : todayIso;
    const from = q.from && isValidIsoDate(q.from) ? q.from : addDays(to, -30);
    const diaries = await listDiaries(userId, from, to);
    return { from, to, diaries };
  });

  app.get('/api/diaries/:date', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const date = dateParam.parse((req.params as { date: string }).date);
    const result = await getDiary(userId, date);
    if (!result) throw AppError.notFound('该日期还没有日记');
    return result;
  });

  // 核心写入：客户端离线积累的块变更一次推上来，服务端做冲突仲裁
  app.post('/api/diaries/:date/batch', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const date = dateParam.parse((req.params as { date: string }).date);
    const body = batchSchema.parse(req.body);
    const settings = await loadSettings(userId);

    const operations: BlockInput[] = body.operations.map((op) => ({
      blockId: op.blockId,
      blockType: op.blockType as BlockType,
      orderKey: op.orderKey,
      vv: op.vv,
      hlc: op.hlc,
      payload: Buffer.from(op.payload, 'base64'),
      mediaRef: op.mediaRef ?? null,
      enc: op.enc,
      nonce: op.nonce ? Buffer.from(op.nonce, 'base64') : null,
      keyId: op.keyId ?? null,
    }));

    return applyBatch(
      userId,
      settings.day_cut_hour,
      config.writeWindowDays,
      {
        diaryDate: date,
        tzId: body.tzId,
        clientNow: body.clientNow,
        deviceId: body.deviceId ?? null,
        operations,
      },
      new Date(),
    );
  });

  app.delete('/api/diaries/:date/blocks/:blockId', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const { date, blockId } = req.params as { date: string; blockId: string };
    const parsedDate = dateParam.parse(date);
    const body = z
      .object({
        vv: z.record(z.string(), z.number().int().nonnegative()),
        hlc: z.string().min(5).max(64),
      })
      .parse(req.body);
    return tombstoneBlock(userId, parsedDate, blockId, body.vv, body.hlc);
  });

  app.get('/api/blocks/:blockId/versions', { preHandler: requireAuth }, async (req) => {
    const userId = currentUserId(req);
    const { blockId } = req.params as { blockId: string };
    const versions = await listBlockVersions(userId, blockId);
    return { blockId, versions };
  });
}
