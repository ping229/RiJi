-- 0009_quota.sql —— 每用户存储配额（防止单个账号占满服务器）
--
-- 默认 5GB。NULL 表示不限制（给信任的账号用）。
-- 只统计媒体文件（图片/语音/视频），文字日记体积可忽略。

ALTER TABLE users ADD COLUMN quota_bytes bigint DEFAULT 5368709120;

COMMENT ON COLUMN users.quota_bytes IS '媒体存储配额（字节）；NULL 表示不限制';
