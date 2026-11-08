-- 0002_replication.sql —— 多节点全量副本复制
--
-- 每个节点都有自己独立的库，互不共享。主节点把每次变更写进 replication_log，
-- 副本按 seq 游标持续拉取并幂等应用；媒体文件按需回源（不整库搬运）。

CREATE TABLE replication_log (
  seq         bigserial PRIMARY KEY,
  user_id     uuid NOT NULL,
  entity      text NOT NULL CHECK (entity IN ('diary', 'block')),
  entity_id   uuid NOT NULL,
  op          text NOT NULL CHECK (op IN ('upsert', 'delete')),
  hlc         text NOT NULL,
  payload     jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX replication_log_entity_idx ON replication_log (entity, entity_id);

-- 本节点已应用到哪个位置
CREATE TABLE replication_state (
  node_id     text PRIMARY KEY,
  cursor      bigint NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- 每个副本的复制进度，供后台展示"落后主节点的变更数"
ALTER TABLE nodes ADD COLUMN replication_cursor bigint NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN replication_lag bigint NOT NULL DEFAULT 0;
