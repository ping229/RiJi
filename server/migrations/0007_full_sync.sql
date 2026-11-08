-- 0007_full_sync.sql —— 手动全量同步（需求 7.2.1）
--
-- 管理员在后台对某个节点点"全量同步"时，主节点只记一个请求标记；
-- 副本在下一次心跳时读到该标记，自行把游标清零重新拉取（幂等，不会重复建数据）。

ALTER TABLE nodes ADD COLUMN full_sync_requested_at timestamptz;
ALTER TABLE nodes ADD COLUMN full_sync_started_at timestamptz;
