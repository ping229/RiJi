/**
 * 副本侧应用逻辑测试。
 *
 * 这些用例针对的是"副本收到主节点日志之后"的行为：
 *   * 用户载荷里的加密材料必须落库（否则副本登录会毁掉密钥）
 *   * 块的仲裁必须按版本向量，而不是只看 HLC
 *   * 历史版本要一起落库
 *
 * 用独立的 riji_replica 库，避免和 api.test.ts 共用 riji_test 时互相清库。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

process.env.RJJ_DATABASE_URL = 'postgres://diary@127.0.0.1:5544/riji_replica';

const { runMigrations } = await import('../src/db/migrate.ts');
const { pool, closePool } = await import('../src/db/pool.ts');
const { applyEntry } = await import('../src/services/replication.ts');
const { encodeHlc } = await import('../src/domain/hlc.ts');

const deviceA = randomUUID();
const deviceB = randomUUID();

function b64(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64');
}

async function reset(): Promise<void> {
  await pool.query(
    'TRUNCATE users, diaries, blocks, block_versions, media, replication_state RESTART IDENTITY CASCADE',
  );
}

/** 块/日记有外键指向用户，先落一个占位账号 */
async function createUser(userId: string): Promise<void> {
  await pool.query(
    `INSERT INTO users (id, username, role, status, password_hash, password_salt)
     VALUES ($1, $2, 'user', 'active', 'h', 's')`,
    [userId, `u_${userId.slice(0, 8)}`],
  );
}

test.before(async () => {
  await runMigrations();
});

test.beforeEach(async () => {
  await reset();
});

test('副本：用户载荷写入后，解密材料与配额都在', async () => {
  const userId = randomUUID();
  await applyEntry({
    seq: 1,
    userId,
    entity: 'user',
    entityId: userId,
    op: 'upsert',
    hlc: '',
    payload: {
      id: userId,
      username: 'copy_user',
      role: 'user',
      status: 'active',
      passwordHash: 'hash',
      passwordSalt: 'salt',
      tzId: 'Asia/Shanghai',
      dayCutHour: 4,
      createdAt: new Date().toISOString(),
      disabledAt: null,
      kdfSalt: 'SALT+base64',
      kdfIterations: 210000,
      keyWrap: 'WRAP+base64',
      keyWrapNonce: 'NONCE+base64',
      keyWrapVersion: 1,
      recoveryWrap: 'RW',
      recoveryNonce: 'RN',
      recoveryCreatedAt: new Date().toISOString(),
      recoveryProof: 'PROOF',
      quotaBytes: '5368709120',
    },
  });

  const { rows } = await pool.query(
    `SELECT kdf_salt, kdf_iterations, key_wrap, key_wrap_nonce, recovery_wrap, recovery_proof, quota_bytes
       FROM users WHERE id = $1`,
    [userId],
  );
  const row = rows[0];
  assert.ok(row, '用户应已复制过来');
  assert.equal(row.kdf_salt, 'SALT+base64', '盐必须在：客户端靠它派生 KEK');
  assert.equal(row.key_wrap, 'WRAP+base64', '包裹体必须在');
  assert.equal(row.key_wrap_nonce, 'NONCE+base64');
  assert.equal(row.recovery_proof, 'PROOF');
  assert.equal(String(row.quota_bytes), '5368709120', '配额应随用户复制');
});

test('副本：按版本向量仲裁，旧的写入不会覆盖新内容', async () => {
  const userId = randomUUID();
  await createUser(userId);
  const diaryId = randomUUID();
  const blockId = randomUUID();
  const today = '2026-11-08';

  const base = {
    blockId,
    diaryId,
    diaryDate: today,
    tzId: 'Asia/Shanghai',
    blockType: 'text',
    orderKey: 'a0',
    enc: 'none',
    nonce: null,
    keyId: null,
    mediaRef: null,
    tombstone: false,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  // 先落 vv={A:2}
  await applyEntry({
    seq: 1,
    userId,
    entity: 'block',
    entityId: blockId,
    op: 'upsert',
    hlc: encodeHlc({ phys: 1000, counter: 0, device: deviceA }),
    payload: {
      ...base,
      vv: { [deviceA]: 2 },
      hlc: encodeHlc({ phys: 1000, counter: 0, device: deviceA }),
      hlcPhys: 1000,
      hlcCounter: 0,
      hlcDevice: deviceA,
      payload: b64({ text: '更新的内容' }),
    },
  });

  // 再送一个"物理时间更晚但因果更旧"的版本：主节点会忽略，副本也必须忽略
  await applyEntry({
    seq: 2,
    userId,
    entity: 'block',
    entityId: blockId,
    op: 'upsert',
    hlc: encodeHlc({ phys: 9999, counter: 0, device: deviceA }),
    payload: {
      ...base,
      vv: { [deviceA]: 1 },
      hlc: encodeHlc({ phys: 9999, counter: 0, device: deviceA }),
      hlcPhys: 9999,
      hlcCounter: 0,
      hlcDevice: deviceA,
      payload: b64({ text: '旧的内容' }),
    },
  });

  const { rows } = await pool.query('SELECT vv, payload FROM blocks WHERE id = $1', [blockId]);
  const text = JSON.parse(Buffer.from(rows[0].payload).toString('utf8')).text;
  assert.equal(text, '更新的内容', '因果更旧的版本不能覆盖（否则副本与主节点会漂移）');
  assert.deepEqual(rows[0].vv, { [deviceA]: 2 });
});

test('副本：并发的两个版本按 HLC 决胜', async () => {
  const userId = randomUUID();
  await createUser(userId);
  const diaryId = randomUUID();
  const blockId = randomUUID();
  const today = '2026-11-08';

  const base = {
    blockId,
    diaryId,
    diaryDate: today,
    tzId: 'Asia/Shanghai',
    blockType: 'text',
    orderKey: 'a0',
    enc: 'none',
    nonce: null,
    keyId: null,
    mediaRef: null,
    tombstone: false,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  const entry = (device: string, phys: number, text: string) => ({
    seq: 1,
    userId,
    entity: 'block' as const,
    entityId: blockId,
    op: 'upsert' as const,
    hlc: encodeHlc({ phys, counter: 0, device }),
    payload: {
      ...base,
      vv: { [device]: 1 },
      hlc: encodeHlc({ phys, counter: 0, device }),
      hlcPhys: phys,
      hlcCounter: 0,
      hlcDevice: device,
      payload: b64({ text }),
    },
  });

  await applyEntry(entry(deviceA, 1000, 'A 版本'));
  await applyEntry(entry(deviceB, 2000, 'B 版本'));

  const { rows } = await pool.query('SELECT payload FROM blocks WHERE id = $1', [blockId]);
  const text = JSON.parse(Buffer.from(rows[0].payload).toString('utf8')).text;
  assert.equal(text, 'B 版本', '并发时 HLC 较大的胜出，与主节点一致');
});

test('副本：块载荷里的历史版本会一起落库', async () => {
  const userId = randomUUID();
  await createUser(userId);
  const diaryId = randomUUID();
  const blockId = randomUUID();
  const versionId = randomUUID();
  const hlc = encodeHlc({ phys: 1000, counter: 0, device: deviceA });

  await applyEntry({
    seq: 1,
    userId,
    entity: 'block',
    entityId: blockId,
    op: 'upsert',
    hlc,
    payload: {
      blockId,
      diaryId,
      diaryDate: '2026-11-08',
      tzId: 'Asia/Shanghai',
      blockType: 'text',
      orderKey: 'a0',
      vv: { [deviceA]: 3 },
      hlc,
      hlcPhys: 1000,
      hlcCounter: 0,
      hlcDevice: deviceA,
      enc: 'none',
      nonce: null,
      keyId: null,
      payload: b64({ text: '当前版本' }),
      mediaRef: null,
      tombstone: false,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      archivedVersions: [
        {
          versionId,
          blockId,
          vv: { [deviceA]: 2 },
          hlc,
          hlcPhys: 900,
          hlcCounter: 0,
          hlcDevice: deviceA,
          enc: 'none',
          nonce: null,
          keyId: null,
          payload: b64({ text: '旧版本' }),
          deviceId: deviceA,
          createdAt: new Date().toISOString(),
        },
      ],
    },
  });

  const { rows } = await pool.query('SELECT payload FROM block_versions WHERE id = $1', [versionId]);
  assert.equal(rows.length, 1, '历史版本应随块一起复制');
  const old = JSON.parse(Buffer.from(rows[0].payload).toString('utf8')).text;
  assert.equal(old, '旧版本', '副本上的版本历史要能还原出内容');
});

test('副本：用户日志缺失时不能让游标卡死（自动补占位账号）', async () => {
  const userId = randomUUID();
  const blockId = randomUUID();
  const diaryId = randomUUID();
  const hlc = encodeHlc({ phys: 1000, counter: 0, device: deviceA });

  // 没有先建 users 行：模拟"用户是用 SQL 建的/老日志被清理过"
  await applyEntry({
    seq: 1,
    userId,
    entity: 'block',
    entityId: blockId,
    op: 'upsert',
    hlc,
    payload: {
      blockId,
      diaryId,
      diaryDate: '2026-11-08',
      tzId: 'Asia/Shanghai',
      blockType: 'text',
      orderKey: 'a0',
      vv: { [deviceA]: 1 },
      hlc,
      hlcPhys: 1000,
      hlcCounter: 0,
      hlcDevice: deviceA,
      enc: 'none',
      nonce: null,
      keyId: null,
      payload: b64({ text: '孤儿数据' }),
      mediaRef: null,
      tombstone: false,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    },
  });

  const users = await pool.query('SELECT username FROM users WHERE id = $1', [userId]);
  assert.equal(users.rows.length, 1, '应自动补一个占位账号，避免外键失败');
  const blocks = await pool.query('SELECT 1 FROM blocks WHERE id = $1', [blockId]);
  assert.equal(blocks.rows.length, 1, '块仍然要落地');
});

test.after(async () => {
  await closePool();
});
