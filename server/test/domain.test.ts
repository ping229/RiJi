/**
 * 三个核心算法的行为锁定测试。
 * 这些规则一旦写错，跨时区、跨设备同步都会出现"日期漂移"或"静默覆盖"，
 * 所以用固定时钟验证，不依赖运行机器的当前时间。
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  businessDate,
  writability,
  writableDates,
  addDays,
  daysBetween,
  isValidIsoDate,
  isClockSuspect,
} from '../src/domain/calendar.ts';
import { compareVv, mergeVv, incrementVv, dominatesOrEqual } from '../src/domain/vv.ts';
import { nextHlc, observeHlc, encodeHlc, compareHlc, decodeHlc } from '../src/domain/hlc.ts';

const SH = 'Asia/Shanghai';

test('业务日：凌晨 4:00 是日切点', () => {
  // 上海 UTC+8
  assert.equal(businessDate(new Date('2026-11-03T15:30:00Z'), SH), '2026-11-03'); // 23:30
  assert.equal(businessDate(new Date('2026-11-03T16:10:00Z'), SH), '2026-11-03'); // 次日 00:10 仍属前一天
  assert.equal(businessDate(new Date('2026-11-03T19:59:59Z'), SH), '2026-11-03'); // 03:59
  assert.equal(businessDate(new Date('2026-11-03T20:00:00Z'), SH), '2026-11-04'); // 04:00 已属新一天
  assert.equal(businessDate(new Date('2026-11-03T20:05:00Z'), SH), '2026-11-04'); // 04:05
});

test('业务日：跨时区计算，且不因时区变化漂移', () => {
  // 2026-11-04T02:00Z 在纽约（EST, UTC-5）为 11-03 21:00
  assert.equal(businessDate(new Date('2026-11-04T02:00:00Z'), 'America/New_York'), '2026-11-03');
  // 同一时刻在上海为 11-04 10:00
  assert.equal(businessDate(new Date('2026-11-04T02:00:00Z'), SH), '2026-11-04');
  // 归属日期一旦算出就是字符串常量，不会因为换时区而改变
  const frozen = businessDate(new Date('2026-11-04T02:00:00Z'), 'America/New_York');
  assert.equal(frozen, '2026-11-03');
});

test('可写窗口：今天 + 过去 7 天共 8 天，未来拒绝', () => {
  const now = new Date('2026-11-10T08:00:00Z'); // 上海 11-10 16:00
  assert.equal(writability('2026-11-10', now, SH).writable, true); // 今天
  assert.equal(writability('2026-11-03', now, SH).writable, true); // 过去 7 天
  assert.equal(writability('2026-11-02', now, SH).writable, false); // 过去 8 天
  assert.equal(writability('2026-11-02', now, SH).reason, 'past-window');
  assert.equal(writability('2026-11-11', now, SH).writable, false); // 未来
  assert.equal(writability('2026-11-11', now, SH).reason, 'future');

  const dates = writableDates(now, SH);
  assert.equal(dates.length, 8);
  assert.equal(dates[0], '2026-11-03');
  assert.equal(dates[7], '2026-11-10');
});

test('日期工具：加减与差值', () => {
  assert.equal(addDays('2026-03-01', -1), '2026-02-28');
  assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(daysBetween('2026-11-03', '2026-11-10'), 7);
  assert.equal(isValidIsoDate('2026-11-03'), true);
  assert.equal(isValidIsoDate('2026-02-30'), false);
});

test('时钟可疑判定', () => {
  const server = new Date('2026-11-10T08:00:00Z');
  assert.equal(isClockSuspect(server, new Date('2026-11-10T08:04:00Z')), false);
  assert.equal(isClockSuspect(server, new Date('2026-11-10T08:06:00Z')), true);
});

test('版本向量：支配与并发', () => {
  assert.equal(compareVv({ a: 1 }, { a: 1 }), 'equal');
  assert.equal(compareVv({ a: 2 }, { a: 1 }), 'a-dominates');
  assert.equal(compareVv({ a: 1 }, { a: 1, b: 1 }), 'b-dominates');
  assert.equal(compareVv({ a: 2, b: 1 }, { a: 1, b: 2 }), 'concurrent');
  assert.equal(dominatesOrEqual({ a: 2, b: 2 }, { a: 1 }), true);
  assert.equal(dominatesOrEqual({ a: 1 }, { a: 2, b: 1 }), false);
  assert.deepEqual(mergeVv({ a: 1 }, { a: 2, b: 3 }), { a: 2, b: 3 });
  assert.deepEqual(incrementVv({ a: 1 }, 'b'), { a: 1, b: 1 });
});

test('HLC：单调递增且可全序比较', () => {
  const t0 = 1_000_000;
  const a = nextHlc(null, t0, 'dev-a');
  assert.deepEqual(a, { phys: t0, counter: 0, device: 'dev-a' });

  // 同一毫秒内再次取，逻辑计数递增
  const b = nextHlc(a, t0, 'dev-a');
  assert.equal(b.counter, 1);

  // 时钟回拨也不能产生更小的时间戳
  const c = nextHlc(b, t0 - 5000, 'dev-a');
  assert.ok(compareHlc(c, b) > 0);

  // 编码后的字符串序与时间序一致
  assert.ok(encodeHlc(a) < encodeHlc(b));
  assert.deepEqual(decodeHlc(encodeHlc(b)), b);

  // 收到远端时间戳后本地时钟被推高
  const remote = { phys: t0 + 10, counter: 3, device: 'dev-b' };
  const observed = observeHlc(b, remote, t0, 'dev-a');
  assert.ok(compareHlc(observed, remote) > 0);
  assert.ok(compareHlc(observed, b) > 0);
});
