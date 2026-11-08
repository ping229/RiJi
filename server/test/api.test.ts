/**
 * 端到端接口测试：用 fastify.inject 驱动真实路由，走真实 PostgreSQL。
 * 覆盖：认证 → 日历窗口 → 块写入 → 并发冲突仲裁 → 版本历史 → 增量同步 → 媒体上传 → 窗口越界拒绝。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

process.env.RJJ_DATABASE_URL = 'postgres://diary@127.0.0.1:5544/riji_test';
process.env.RJJ_MEDIA_DIR = 'C:\\dev\\riji-test-media';

const { buildApp } = await import('../src/app.ts');
const { runMigrations } = await import('../src/db/migrate.ts');
const { pool, closePool } = await import('../src/db/pool.ts');
const { hashPassword } = await import('../src/auth/password.ts');
const { encodeHlc, nextHlc } = await import('../src/domain/hlc.ts');
const { addDays } = await import('../src/domain/calendar.ts');

const app = await buildApp();
let token = '';
let adminToken = '';
let deviceA = randomUUID();
let deviceB = randomUUID();
let todayIso = '';

async function resetDatabase(): Promise<void> {
  await pool.query(
    'TRUNCATE users, devices, diaries, blocks, block_versions, media, changes, conflicts, refresh_tokens, audit_log, nodes, replication_log, replication_state RESTART IDENTITY CASCADE',
  );
}

function authHeaders(): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

function makeBlock(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const hlc = encodeHlc(nextHlc(null, Date.now(), deviceA));
  return {
    blockId: randomUUID(),
    blockType: 'text',
    orderKey: 'a0',
    vv: { [deviceA]: 1 },
    hlc,
    payload: Buffer.from(JSON.stringify({ text: '第一段' }), 'utf8').toString('base64'),
    enc: 'none',
    ...overrides,
  };
}

test.before(async () => {
  await runMigrations();
});

test.beforeEach(async () => {
  await resetDatabase();
  const record = await hashPassword('test-password-123');
  await pool.query(
    `INSERT INTO users (username, role, password_hash, password_salt, tz_id, day_cut_hour)
     VALUES ('tester', 'user', $1, $2, 'Asia/Shanghai', 4)`,
    [record.hash, record.salt],
  );
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'tester', password: 'test-password-123', device: { name: 'PC-A', platform: 'windows' } },
  });
  assert.equal(login.statusCode, 200, login.body);
  token = JSON.parse(login.body).accessToken;

  const cal = await app.inject({ method: 'GET', url: '/api/calendar', headers: authHeaders() });
  assert.equal(cal.statusCode, 200, cal.body);
  todayIso = JSON.parse(cal.body).today;

  // 管理员账号，用于后台接口测试
  const adminRecord = await hashPassword('admin-password-123');
  await pool.query(
    `INSERT INTO users (username, role, password_hash, password_salt) VALUES ('boss', 'admin', $1, $2)`,
    [adminRecord.hash, adminRecord.salt],
  );
  const adminLogin = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'boss', password: 'admin-password-123' },
  });
  assert.equal(adminLogin.statusCode, 200, adminLogin.body);
  adminToken = JSON.parse(adminLogin.body).accessToken;
});

test('健康检查与鉴权边界', async () => {
  const health = await app.inject({ method: 'GET', url: '/healthz' });
  assert.equal(health.statusCode, 200);

  const anonymous = await app.inject({ method: 'GET', url: '/api/calendar' });
  assert.equal(anonymous.statusCode, 401);

  const me = await app.inject({ method: 'GET', url: '/api/auth/me', headers: authHeaders() });
  assert.equal(me.statusCode, 200);
  assert.equal(JSON.parse(me.body).user.username, 'tester');
});

test('日历窗口：返回 8 个可写日期且今天在最末', async () => {
  const cal = await app.inject({ method: 'GET', url: '/api/calendar', headers: authHeaders() });
  const body = JSON.parse(cal.body);
  assert.equal(body.writableDates.length, 8);
  assert.equal(body.writableDates[7], body.today);
  assert.equal(body.writableDates[0], addDays(body.today, -7));
});

test('写入块并读回，顺序与内容一致', async () => {
  const b1 = makeBlock({ orderKey: 'a0' });
  const b2 = makeBlock({ orderKey: 'a1', payload: Buffer.from('{"text":"第二段"}').toString('base64') });

  const write = await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [b2, b1],
    },
  });
  assert.equal(write.statusCode, 200, write.body);
  const writeBody = JSON.parse(write.body);
  assert.equal(writeBody.blocks.length, 2);
  assert.deepEqual(
    writeBody.blocks.map((b: { orderKey: string }) => b.orderKey),
    ['a0', 'a1'],
  );

  const read = await app.inject({ method: 'GET', url: `/api/diaries/${todayIso}`, headers: authHeaders() });
  assert.equal(read.statusCode, 200, read.body);
  const readBody = JSON.parse(read.body);
  assert.equal(readBody.blocks.length, 2);
  assert.equal(readBody.diary.blockCount, 2);
});

test('并发修改：两版都保留，HLC 较新者胜出并留下冲突记录', async () => {
  const blockId = randomUUID();
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock({ blockId, vv: { [deviceA]: 1 } })],
    },
  });

  // 设备 B 基于同一祖先并发修改（没有见过设备 A 的改动，才是真并发），时间更晚
  const laterHlc = encodeHlc(nextHlc(null, Date.now() + 1000, deviceB));
  const second = await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceB,
      operations: [
        makeBlock({
          blockId,
          vv: { [deviceB]: 1 },
          hlc: laterHlc,
          payload: Buffer.from('{"text":"设备B的修改"}').toString('base64'),
        }),
      ],
    },
  });
  assert.equal(second.statusCode, 200, second.body);
  const secondBody = JSON.parse(second.body);
  assert.equal(secondBody.conflicts.length, 1);
  assert.equal(secondBody.blocks.length, 1);

  // 落败版本必须能在版本历史里找回，不能凭空消失
  const versions = await app.inject({
    method: 'GET',
    url: `/api/blocks/${blockId}/versions`,
    headers: authHeaders(),
  });
  assert.equal(versions.statusCode, 200);
  assert.ok(JSON.parse(versions.body).versions.length >= 1);
});

test('过时写入不会覆盖较新内容', async () => {
  const blockId = randomUUID();
  const t0 = Date.now();
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [
        makeBlock({ blockId, vv: { [deviceA]: 2 }, hlc: encodeHlc({ phys: t0 + 5000, counter: 0, device: deviceA }) }),
      ],
    },
  });

  const stale = await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceB,
      operations: [
        makeBlock({ blockId, vv: { [deviceA]: 1 }, hlc: encodeHlc({ phys: t0, counter: 0, device: deviceB }) }),
      ],
    },
  });
  assert.equal(stale.statusCode, 200);
  const payload = Buffer.from(JSON.parse(stale.body).blocks[0].payload, 'base64').toString('utf8');
  assert.match(payload, /第一段/);
});

test('时间窗口：超过 7 天的日期被拒绝写入', async () => {
  const tooOld = addDays(todayIso, -10);
  const write = await app.inject({
    method: 'POST',
    url: `/api/diaries/${tooOld}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });
  assert.equal(write.statusCode, 422, write.body);
  assert.equal(JSON.parse(write.body).error.code, 'DATE_WINDOW_VIOLATION');

  const future = addDays(todayIso, 1);
  const futureWrite = await app.inject({
    method: 'POST',
    url: `/api/diaries/${future}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });
  assert.equal(futureWrite.statusCode, 422);
  assert.equal(JSON.parse(futureWrite.body).error.details.reason, 'future');
});

test('增量同步：游标推进且能取到变更', async () => {
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });

  const first = await app.inject({ method: 'GET', url: '/api/sync/changes?since=0', headers: authHeaders() });
  assert.equal(first.statusCode, 200, first.body);
  const firstBody = JSON.parse(first.body);
  assert.ok(firstBody.changes.length >= 1);
  assert.equal(firstBody.hasMore, false);

  const second = await app.inject({
    method: 'GET',
    url: `/api/sync/changes?since=${firstBody.cursor}`,
    headers: authHeaders(),
  });
  assert.equal(JSON.parse(second.body).changes.length, 0);
});

test('日记列表：日期字符串不得因时区换算偏移一天', async () => {
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });

  const list = await app.inject({ method: 'GET', url: '/api/diaries', headers: authHeaders() });
  assert.equal(list.statusCode, 200, list.body);
  const diaries = JSON.parse(list.body).diaries as Array<{ diaryDate: string }>;
  assert.equal(diaries.length, 1);
  assert.equal(diaries[0]!.diaryDate, todayIso);

  const detail = await app.inject({ method: 'GET', url: `/api/diaries/${todayIso}`, headers: authHeaders() });
  assert.equal(JSON.parse(detail.body).diary.diaryDate, todayIso);
});

test('媒体：上传后可下载，且带 Range 支持', async () => {
  const mediaKey = 'a'.repeat(32);
  const content = Buffer.from('这是一段测试用的媒体内容', 'utf8');

  const upload = await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: {
      ...authHeaders(),
      'content-type': 'application/octet-stream',
      'x-media-key': mediaKey,
      'x-media-mime': 'audio/mp4',
      'x-media-duration': '1200',
    },
    payload: content,
  });
  assert.equal(upload.statusCode, 200, upload.body);
  assert.equal(JSON.parse(upload.body).bytes, content.length);

  const download = await app.inject({
    method: 'GET',
    url: `/api/media/${mediaKey}`,
    headers: authHeaders(),
  });
  assert.equal(download.statusCode, 200, download.body);
  assert.deepEqual(download.rawPayload, content);

  const ranged = await app.inject({
    method: 'GET',
    url: `/api/media/${mediaKey}`,
    headers: { ...authHeaders(), range: 'bytes=0-5' },
  });
  assert.equal(ranged.statusCode, 206);
  assert.deepEqual(ranged.rawPayload, content.subarray(0, 6));
});

test('数据隔离：他人媒体不可读', async () => {
  const mediaKey = 'b'.repeat(32);
  await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: {
      ...authHeaders(),
      'content-type': 'application/octet-stream',
      'x-media-key': mediaKey,
      'x-media-mime': 'image/jpeg',
    },
    payload: Buffer.from('img'),
  });

  // 换一个用户登录，尝试读取别人的媒体
  const record = await hashPassword('other-password-123');
  await pool.query(
    `INSERT INTO users (username, role, password_hash, password_salt) VALUES ('other', 'user', $1, $2)`,
    [record.hash, record.salt],
  );
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'other', password: 'other-password-123' },
  });
  const otherToken = JSON.parse(login.body).accessToken;

  const forbidden = await app.inject({
    method: 'GET',
    url: `/api/media/${mediaKey}`,
    headers: { authorization: `Bearer ${otherToken}` },
  });
  assert.equal(forbidden.statusCode, 404);
});

test('写入会进入复制日志，供其他节点追平', async () => {
  const { rows: before } = await pool.query<{ n: number }>('SELECT count(*)::int AS n FROM replication_log');
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });
  const { rows: after } = await pool.query<{ n: number; entities: string | null }>(
    'SELECT count(*)::int AS n, string_agg(DISTINCT entity, \',\') AS entities FROM replication_log',
  );
  assert.ok((after[0]?.n ?? 0) > (before[0]?.n ?? 0), '写日记必须产生复制日志');
  assert.ok((after[0]?.entities ?? '').includes('block'), '复制日志应包含块变更');
});

test('管理员后台：能看到数量与状态，但拿不到任何日记内容', async () => {
  const admin = { authorization: `Bearer ${adminToken}` };

  const stats = await app.inject({ method: 'GET', url: '/api/admin/stats', headers: admin });
  assert.equal(stats.statusCode, 200, stats.body);
  assert.equal(typeof JSON.parse(stats.body).users, 'number');

  // 先写一篇日记，确认它不会以任何形式出现在管理接口里
  await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock()],
    },
  });

  const users = await app.inject({ method: 'GET', url: '/api/admin/users', headers: admin });
  assert.equal(users.statusCode, 200, users.body);
  const body = JSON.parse(users.body);
  const serialized = JSON.stringify(body);
  assert.ok(!serialized.includes('第一段'), '管理接口不得泄露日记正文');
  assert.ok(!serialized.includes('payload'), '管理接口不得返回块载荷字段');

  const tester = body.users.find((u: { username: string }) => u.username === 'tester');
  const forbidden = await app.inject({
    method: 'GET',
    url: `/api/admin/users/${tester.id}/diaries`,
    headers: admin,
  });
  assert.equal(forbidden.statusCode, 403);
});

test('管理员接口：普通用户一律 403', async () => {
  for (const url of ['/api/admin/stats', '/api/admin/users', '/api/admin/nodes', '/api/admin/audit']) {
    const res = await app.inject({ method: 'GET', url, headers: authHeaders() });
    assert.equal(res.statusCode, 403, `${url} 应该拒绝普通用户`);
  }

  const anonymous = await app.inject({ method: 'GET', url: '/api/admin/stats' });
  assert.equal(anonymous.statusCode, 401);
});

test('禁用用户后立即无法登录，且审计留痕', async () => {
  const admin = { authorization: `Bearer ${adminToken}` };
  const users = await app.inject({ method: 'GET', url: '/api/admin/users', headers: admin });
  const tester = JSON.parse(users.body).users.find((u: { username: string }) => u.username === 'tester');

  const disable = await app.inject({
    method: 'POST',
    url: `/api/admin/users/${tester.id}/disable`,
    headers: admin,
    payload: {},
  });
  assert.equal(disable.statusCode, 200, disable.body);

  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'tester', password: 'test-password-123' },
  });
  assert.equal(login.statusCode, 403);
  assert.equal(JSON.parse(login.body).error.code, 'ACCOUNT_DISABLED');

  const audit = await app.inject({ method: 'GET', url: '/api/admin/audit', headers: admin });
  const entries = JSON.parse(audit.body).entries as Array<{ action: string }>;
  assert.ok(entries.some((e) => e.action === 'user.disable'), '禁用操作必须写入审计日志');
});

test('删除节点：唯一持有数据的节点被阻止', async () => {
  const admin = { authorization: `Bearer ${adminToken}` };
  const nodes = await app.inject({ method: 'GET', url: '/api/admin/nodes', headers: admin });
  const node = JSON.parse(nodes.body).nodes[0] as { id: string } | undefined;
  if (!node) return; // 未注册节点时跳过

  const retire = await app.inject({
    method: 'POST',
    url: `/api/admin/nodes/${node.id}/retire`,
    headers: admin,
    payload: {},
  });
  assert.equal(retire.statusCode, 409);
  assert.equal(JSON.parse(retire.body).error.code, 'UNIQUE_COPY');
});


test('存储配额：超限的上传被拒绝，调整配额后恢复', async () => {
  const admin = { authorization: `Bearer ${adminToken}` };
  const username = `quota_${Date.now()}`;

  // 管理员建一个 1MB 配额的用户（0.001 GB）
  const create = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: admin,
    payload: { username, password: 'quota-pass-2026', role: 'user', quotaGb: 0.001 },
  });
  assert.equal(create.statusCode, 201, create.body);
  const userId = JSON.parse(create.body).id as string;

  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password: 'quota-pass-2026' },
  });
  assert.equal(login.statusCode, 200, login.body);
  const userHeaders = {
    authorization: `Bearer ${JSON.parse(login.body).accessToken}`,
    'content-type': 'application/octet-stream',
    'x-media-mime': 'image/jpeg',
  };

  // 2MB 超过 1MB 配额 → 413 且错误码是 QUOTA_EXCEEDED
  const big = Buffer.alloc(2 * 1024 * 1024, 7);
  const rejected = await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: { ...userHeaders, 'x-media-key': 'ab'.repeat(16) },
    payload: big,
  });
  assert.equal(rejected.statusCode, 413, rejected.body);
  const errBody = JSON.parse(rejected.body);
  assert.equal(errBody.error.code, 'QUOTA_EXCEEDED');
  assert.ok(String(errBody.error.message).includes('存储空间不足'), '要说明是空间不足');
  assert.ok(String(errBody.error.message).includes('GB') || String(errBody.error.message).includes('MB'),
    '提示里要带具体数字');

  // 100KB 在配额内 → 允许
  const small = Buffer.alloc(100 * 1024, 3);
  const ok = await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: { ...userHeaders, 'x-media-key': 'cd'.repeat(16) },
    payload: small,
  });
  assert.equal(ok.statusCode, 200, ok.body);

  // 用量接口能读到用量与配额
  const usage = await app.inject({ method: 'GET', url: '/api/me/storage', headers: { authorization: userHeaders.authorization } });
  assert.equal(usage.statusCode, 200, usage.body);
  const usageBody = JSON.parse(usage.body);
  assert.equal(usageBody.usedBytes, small.length);
  assert.ok(usageBody.quotaBytes > 0);

  // 管理员把配额调到 1GB → 原来那个 2MB 现在能传
  const patch = await app.inject({
    method: 'PATCH',
    url: `/api/admin/users/${userId}/quota`,
    headers: admin,
    payload: { quotaGb: 1 },
  });
  assert.equal(patch.statusCode, 200, patch.body);

  const after = await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: { ...userHeaders, 'x-media-key': 'ef'.repeat(16) },
    payload: big,
  });
  assert.equal(after.statusCode, 200, after.body);

  // 管理端用户列表带出用量与配额
  const list = await app.inject({ method: 'GET', url: '/api/admin/users', headers: admin });
  const row = JSON.parse(list.body).users.find((u: { username: string }) => u.username === username);
  assert.ok(row, '列表里应有该用户');
  assert.ok(row.usedBytes >= small.length, '应带出已用字节数');
  assert.ok(row.quotaBytes >= 1024 * 1024 * 1024, '应带出配额');
});

// ------------------------------------------------------------ 多节点复制载荷

const REPLICATION_TOKEN = 'dev-replication-token';

function replicaHeaders(): Record<string, string> {
  return { 'x-replication-token': REPLICATION_TOKEN };
}

test('复制：用户载荷带全解密材料（盐、包裹体、恢复短语、配额）', async () => {
  const salt = Buffer.from('0123456789abcdef').toString('base64');
  const putSalt = await app.inject({
    method: 'POST',
    url: '/api/auth/kdf-salt',
    headers: authHeaders(),
    payload: { salt, iterations: 210000 },
  });
  assert.equal(putSalt.statusCode, 200, putSalt.body);

  const wrap = Buffer.alloc(64, 7).toString('base64');
  const nonce = Buffer.alloc(12, 3).toString('base64');
  const putWrap = await app.inject({
    method: 'PUT',
    url: '/api/auth/key-wrap',
    headers: authHeaders(),
    payload: { wrap, nonce },
  });
  assert.equal(putWrap.statusCode, 200, putWrap.body);

  const { rows } = await pool.query<{ id: string }>("SELECT id FROM users WHERE username = 'tester'");
  const userId = rows[0]!.id;

  const snap = await app.inject({
    method: 'GET',
    url: '/api/replication/snapshot?kind=user&limit=50',
    headers: replicaHeaders(),
  });
  assert.equal(snap.statusCode, 200, snap.body);
  const mine = (
    JSON.parse(snap.body).items as Array<{ payload: Record<string, unknown>; userId: string }>
  ).find((i) => i.userId === userId);
  assert.ok(mine, '快照里应有该用户');

  // 少了这几个字段，副本上的客户端会以为"还没启用加密"，从而生成新密钥覆盖包裹体
  assert.equal(mine.payload.kdfSalt, salt);
  assert.equal(mine.payload.kdfIterations, 210000);
  assert.equal(mine.payload.keyWrap, wrap);
  assert.equal(mine.payload.keyWrapNonce, nonce);
  assert.equal(mine.payload.keyWrapVersion, 1);
  assert.ok('recoveryWrap' in mine.payload, '恢复短语包裹体字段必须在');
  assert.ok('recoveryProof' in mine.payload, '恢复短语证明字段必须在');
  assert.ok('quotaBytes' in mine.payload, '配额必须随用户复制');
});

test('复制：块的版本历史随日志与快照一起下发', async () => {
  const blockId = randomUUID();
  const write = async (vv: Record<string, number>, text: string) => {
    const res = await app.inject({
      method: 'POST',
      url: `/api/diaries/${todayIso}/batch`,
      headers: authHeaders(),
      payload: {
        tzId: 'Asia/Shanghai',
        clientNow: new Date().toISOString(),
        deviceId: deviceA,
        operations: [
          makeBlock({
            blockId,
            vv,
            payload: Buffer.from(JSON.stringify({ text }), 'utf8').toString('base64'),
          }),
        ],
      },
    });
    assert.equal(res.statusCode, 200, res.body);
  };

  await write({ [deviceA]: 1 }, '第一版');
  await write({ [deviceA]: 2 }, '第二版');

  const log = await app.inject({
    method: 'GET',
    url: '/api/replication/log?since=0&limit=200',
    headers: replicaHeaders(),
  });
  assert.equal(log.statusCode, 200, log.body);
  const entries = (JSON.parse(log.body).entries as Array<{
    entity: string;
    payload: { blockId?: string; archivedVersions?: unknown[] };
  }>).filter((e) => e.entity === 'block' && e.payload.blockId === blockId);
  assert.ok(entries.length >= 2, '两次写入都应进复制日志');

  const last = entries[entries.length - 1]!;
  assert.ok(Array.isArray(last.payload.archivedVersions), '块载荷应带历史版本');
  assert.equal(last.payload.archivedVersions!.length, 1, '第一版应被归档');

  const snapshot = await app.inject({
    method: 'GET',
    url: '/api/replication/snapshot?kind=version&limit=200',
    headers: replicaHeaders(),
  });
  assert.equal(snapshot.statusCode, 200, snapshot.body);
  const versions = JSON.parse(snapshot.body).items as Array<{ payload: { blockId: string } }>;
  assert.ok(versions.some((v) => v.payload.blockId === blockId), '基线快照应包含历史版本');
});

test('复制：加密媒体的元数据带 nonce（否则副本解不开）', async () => {
  const { randomBytes } = await import('node:crypto');
  const key = randomBytes(32).toString('hex');
  const nonce = randomBytes(12).toString('base64');
  const body = randomBytes(256);

  const upload = await app.inject({
    method: 'POST',
    url: '/api/media',
    headers: {
      ...authHeaders(),
      'content-type': 'application/octet-stream',
      'x-media-key': key,
      'x-media-mime': 'image/jpeg',
      'x-media-enc': 'aes-256-gcm',
      'x-media-nonce': nonce,
    },
    payload: body,
  });
  assert.equal(upload.statusCode, 200, upload.body);

  const { rows } = await pool.query<{ id: string }>("SELECT id FROM users WHERE username = 'tester'");
  const meta = await app.inject({
    method: 'GET',
    url: `/api/replication/media/${key}/meta?userId=${rows[0]!.id}`,
    headers: replicaHeaders(),
  });
  assert.equal(meta.statusCode, 200, meta.body);
  const metaBody = JSON.parse(meta.body);
  assert.equal(metaBody.nonce, nonce, '副本必须能拿到 nonce');
  assert.equal(metaBody.enc, 'aes-256-gcm');

  // 完整下载也必须带 nonce 头
  const download = await app.inject({
    method: 'GET',
    url: `/api/replication/media/${key}?userId=${rows[0]!.id}`,
    headers: replicaHeaders(),
  });
  assert.equal(download.statusCode, 200);
  assert.equal(download.headers['x-media-nonce'], nonce);
});

test('清理任务：过期历史版本与变更日志会被删除，新数据不受影响', async () => {
  const { runRetentionOnce } = await import('../src/services/retention.ts');
  const { rows: users } = await pool.query<{ id: string }>("SELECT id FROM users WHERE username = 'tester'");
  const userId = users[0]!.id;

  // 一条 40 天前的变更日志
  await pool.query(
    `INSERT INTO changes (user_id, entity, entity_id, op, hlc, created_at)
     VALUES ($1, 'diary', $2, 'upsert', 'old', now() - interval '40 days')`,
    [userId, randomUUID()],
  );
  // 一条新变更日志
  await pool.query(
    `INSERT INTO changes (user_id, entity, entity_id, op, hlc) VALUES ($1, 'diary', $2, 'upsert', 'new')`,
    [userId, randomUUID()],
  );

  // 造一个块与一份过期历史版本
  const blockId = randomUUID();
  const write = await app.inject({
    method: 'POST',
    url: `/api/diaries/${todayIso}/batch`,
    headers: authHeaders(),
    payload: {
      tzId: 'Asia/Shanghai',
      clientNow: new Date().toISOString(),
      deviceId: deviceA,
      operations: [makeBlock({ blockId })],
    },
  });
  assert.equal(write.statusCode, 200, write.body);
  await pool.query(
    `INSERT INTO block_versions (block_id, vv, hlc, hlc_phys, hlc_counter, hlc_device, enc, payload, retained_until)
     VALUES ($1, '{}'::jsonb, 'old', 1, 0, $2, 'none', $3, now() - interval '1 day')`,
    [blockId, deviceA, Buffer.from('{}')],
  );

  const result = await runRetentionOnce();
  assert.ok(result.changes >= 1, '过期变更日志应被清理');
  assert.ok(result.blockVersions >= 1, '过期历史版本应被清理');

  const remaining = await pool.query<{ n: number }>('SELECT count(*)::int AS n FROM changes WHERE hlc = $1', ['new']);
  assert.equal(remaining.rows[0]!.n, 1, '新变更日志必须保留');
});

test.after(async () => {
  await app.close();
  await closePool();
});