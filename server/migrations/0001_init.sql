-- 0001_init.sql —— 日记平台初始表结构
-- 设计要点：
--   * 一天一篇日记：UNIQUE(user_id, diary_date)
--   * 块序列用 order_key 做分数排序键，插入/重排不必重编号
--   * 块内容一律以 bytea 存放（密文外壳），enc 字段标注当前是否已加密
--   * 所有查询必须带 user_id 过滤（数据隔离，需求 6.2）

CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username        text NOT NULL UNIQUE,
  role            text NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled', 'pending_delete')),
  password_hash   text NOT NULL,
  password_salt   text NOT NULL,
  tz_id           text NOT NULL DEFAULT 'Asia/Shanghai',
  day_cut_hour    int  NOT NULL DEFAULT 4 CHECK (day_cut_hour BETWEEN 0 AND 23),
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_active_at  timestamptz,
  disabled_at     timestamptz
);

CREATE TABLE devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          text NOT NULL,
  platform      text NOT NULL CHECK (platform IN ('windows', 'android', 'macos', 'linux', 'unknown')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz,
  revoked_at    timestamptz
);
CREATE INDEX devices_user_idx ON devices (user_id);

-- 日记本体：只存结构性字段，正文在 blocks 里
CREATE TABLE diaries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  diary_date    date NOT NULL,
  tz_id         text NOT NULL,
  vv            jsonb NOT NULL DEFAULT '{}'::jsonb,
  time_suspect  boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, diary_date)
);

-- 块序列：正文的唯一载体，有序、可插入、可墓碑
CREATE TABLE blocks (
  id             uuid PRIMARY KEY,
  diary_id       uuid NOT NULL REFERENCES diaries(id) ON DELETE CASCADE,
  block_type     text NOT NULL CHECK (block_type IN ('text', 'image', 'audio', 'video', 'divider')),
  order_key      text NOT NULL,
  vv             jsonb NOT NULL DEFAULT '{}'::jsonb,
  hlc            text NOT NULL,
  hlc_phys       bigint NOT NULL,
  hlc_counter    int NOT NULL,
  hlc_device     text NOT NULL,
  enc            text NOT NULL DEFAULT 'none' CHECK (enc IN ('none', 'aes-256-gcm')),
  nonce          bytea,
  key_id         text,
  payload        bytea NOT NULL,
  media_ref      text,
  tombstone      boolean NOT NULL DEFAULT false,
  tombstoned_at  timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX blocks_diary_order_idx ON blocks (diary_id, order_key);
CREATE INDEX blocks_media_ref_idx ON blocks (media_ref) WHERE media_ref IS NOT NULL;
CREATE INDEX blocks_tombstone_idx ON blocks (tombstoned_at) WHERE tombstone;

-- 冲突历史：被覆盖的版本留在这里，30 天后由压缩任务清理
CREATE TABLE block_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  block_id       uuid NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
  vv             jsonb NOT NULL,
  hlc            text NOT NULL,
  hlc_phys       bigint NOT NULL,
  hlc_counter    int NOT NULL,
  hlc_device     text NOT NULL,
  enc            text NOT NULL,
  nonce          bytea,
  key_id         text,
  payload        bytea NOT NULL,
  device_id      uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  retained_until timestamptz NOT NULL DEFAULT (now() + interval '30 days')
);
CREATE INDEX block_versions_block_idx ON block_versions (block_id, hlc_phys DESC);

-- 媒体：按用户隔离的 keyed-hash 去重，服务端只见密文与元数据
CREATE TABLE media (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_key   text NOT NULL,
  byte_size   bigint NOT NULL,
  mime        text,
  enc         text NOT NULL DEFAULT 'none' CHECK (enc IN ('none', 'aes-256-gcm')),
  nonce       bytea,
  duration_ms int,
  width       int,
  height      int,
  blob_path   text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, media_key)
);

-- 增量同步变更日志：客户端游标 = 最后消费的 seq
CREATE TABLE changes (
  seq         bigserial PRIMARY KEY,
  user_id     uuid NOT NULL,
  entity      text NOT NULL CHECK (entity IN ('diary', 'block')),
  entity_id   uuid NOT NULL,
  op          text NOT NULL CHECK (op IN ('upsert', 'delete')),
  hlc         text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX changes_user_seq_idx ON changes (user_id, seq);

-- 待用户裁决的并发冲突
CREATE TABLE conflicts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL,
  diary_id     uuid NOT NULL,
  block_id     uuid NOT NULL,
  winner_id    uuid,
  loser_id     uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz
);
CREATE INDEX conflicts_user_idx ON conflicts (user_id, resolved_at);

-- 集群节点（全量副本）
CREATE TABLE nodes (
  id                 text PRIMARY KEY,
  role               text NOT NULL DEFAULT 'replica' CHECK (role IN ('primary', 'replica')),
  status             text NOT NULL DEFAULT 'online'
                     CHECK (status IN ('online', 'syncing', 'offline', 'failed', 'retiring', 'retired', 'disabled')),
  endpoint           text,
  epoch              int NOT NULL DEFAULT 1,
  last_heartbeat_at  timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE refresh_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id   uuid REFERENCES devices(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
  id           bigserial PRIMARY KEY,
  actor_id     uuid,
  action       text NOT NULL,
  target_type  text,
  target_id    text,
  detail       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_created_idx ON audit_log (created_at DESC);
