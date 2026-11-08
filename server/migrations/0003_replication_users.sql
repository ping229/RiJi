-- 0003_replication_users.sql —— 用户账号也需要在各节点之间复制
--
-- 副本上没有对应用户记录时，日记会因为外键约束无法落地，
-- 所以用户（含密码哈希）必须和日记一起复制，节点间才能真正互为全量副本。

ALTER TABLE replication_log DROP CONSTRAINT IF EXISTS replication_log_entity_check;
ALTER TABLE replication_log
  ADD CONSTRAINT replication_log_entity_check CHECK (entity IN ('user', 'diary', 'block'));
