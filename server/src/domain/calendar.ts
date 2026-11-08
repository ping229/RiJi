/**
 * 日记的时间归属规则（需求 3.1）
 *
 * 三条不可混淆的规则：
 *  1. 业务日在"写入时"计算一次并冻结，之后永不重算（跨时区不漂移）
 *  2. "今天"和可写窗口在每次读取时用设备当前时区重新计算
 *  3. 日切点为本地时间凌晨 4:00，向前平移 4 小时后再取日期
 */

export const DEFAULT_DAY_CUT_HOUR = 4;
/** 补写窗口：今天 + 过去 7 天 = 8 个可写日期 */
export const WRITE_WINDOW_DAYS = 7;

const DAY_MS = 86_400_000;
const formatterCache = new Map<string, Intl.DateTimeFormat>();

function formatterFor(tzId: string): Intl.DateTimeFormat {
  let f = formatterCache.get(tzId);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tzId,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });
    formatterCache.set(tzId, f);
  }
  return f;
}

export function isKnownTimeZone(tzId: string): boolean {
  try {
    formatterFor(tzId).format(new Date());
    return true;
  } catch {
    return false;
  }
}

export interface LocalParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

/** 取出某一时刻在指定时区下的本地时间分量 */
export function localParts(at: Date, tzId: string): LocalParts {
  const parts = formatterFor(tzId).formatToParts(at);
  const pick = (type: Intl.DateTimeFormatPartTypes): number => {
    const found = parts.find((p) => p.type === type);
    if (!found) throw new Error(`无法取得时区 ${tzId} 的 ${type} 分量`);
    return Number.parseInt(found.value, 10);
  };
  return {
    year: pick('year'),
    month: pick('month'),
    day: pick('day'),
    hour: pick('hour') % 24,
    minute: pick('minute'),
    second: pick('second'),
  };
}

export function isoDate(year: number, month: number, day: number): string {
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

export function isValidIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const ms = utcMillisOf(value);
  const d = new Date(ms);
  return isoDate(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()) === value;
}

function utcMillisOf(iso: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) throw new Error(`非法日期格式: ${iso}`);
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const ms = Date.UTC(year, month - 1, day);
  if (!Number.isFinite(ms)) throw new Error(`非法日期: ${iso}`);
  return ms;
}

export function addDays(iso: string, delta: number): string {
  const d = new Date(utcMillisOf(iso) + delta * DAY_MS);
  return isoDate(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
}

/** toIso 相对 fromIso 的天数；正数表示 toIso 更晚 */
export function daysBetween(fromIso: string, toIso: string): number {
  return Math.round((utcMillisOf(toIso) - utcMillisOf(fromIso)) / DAY_MS);
}

/**
 * 计算某一时刻归属的业务日。
 * 例：Asia/Shanghai 时区下，2026-11-04 03:30 本地时间 → 归属 2026-11-03。
 */
export function businessDate(at: Date, tzId: string, cutHour = DEFAULT_DAY_CUT_HOUR): string {
  const p = localParts(at, tzId);
  const base = isoDate(p.year, p.month, p.day);
  return p.hour < cutHour ? addDays(base, -1) : base;
}

/** 当前时刻的"今天"（业务日口径） */
export function today(at: Date, tzId: string, cutHour = DEFAULT_DAY_CUT_HOUR): string {
  return businessDate(at, tzId, cutHour);
}

export type NotWritableReason = 'future' | 'past-window';

export interface Writability {
  writable: boolean;
  reason?: NotWritableReason;
  /** 当前业务日 */
  today: string;
  /** 日记日相对今天的天数：负数=未来，0=今天，正数=过去 */
  offsetDays: number;
}

/**
 * 判断某一天是否在可写窗口内。
 * 窗口为闭区间 [today - windowDays, today]；未来日期一律拒绝。
 */
export function writability(
  diaryDate: string,
  now: Date,
  tzId: string,
  opts: { cutHour?: number; windowDays?: number } = {},
): Writability {
  const cutHour = opts.cutHour ?? DEFAULT_DAY_CUT_HOUR;
  const windowDays = opts.windowDays ?? WRITE_WINDOW_DAYS;
  const todayIso = businessDate(now, tzId, cutHour);
  const offset = daysBetween(diaryDate, todayIso);
  if (offset < 0) return { writable: false, reason: 'future', today: todayIso, offsetDays: offset };
  if (offset > windowDays) {
    return { writable: false, reason: 'past-window', today: todayIso, offsetDays: offset };
  }
  return { writable: true, today: todayIso, offsetDays: offset };
}

/** 当前窗口内全部可写日期，从旧到新 */
export function writableDates(now: Date, tzId: string, opts: { cutHour?: number; windowDays?: number } = {}): string[] {
  const cutHour = opts.cutHour ?? DEFAULT_DAY_CUT_HOUR;
  const windowDays = opts.windowDays ?? WRITE_WINDOW_DAYS;
  const todayIso = businessDate(now, tzId, cutHour);
  const out: string[] = [];
  for (let i = windowDays; i >= 0; i -= 1) out.push(addDays(todayIso, -i));
  return out;
}

/** 设备时间与服务端时间偏差是否已超过告警阈值（需求 3.1：标为"时间可疑"） */
export function isClockSuspect(serverNow: Date, clientReportedNow: Date, thresholdSeconds = 300): boolean {
  const skew = Math.abs(serverNow.getTime() - clientReportedNow.getTime()) / 1000;
  return skew > thresholdSeconds;
}
