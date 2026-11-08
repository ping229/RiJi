-- 0008_media_jobs.sql —— 媒体处理队列（需求 5.2）
--
-- 上传的原始文件可能不是统一编码（iPhone 的 .mov、录屏的 .webm、某些 .wav）。
-- 这里记录"这个媒体要不要归一到 H.264/AAC"，以及处理到哪一步了。
--
-- 设计原则：**转码失败绝不能影响日记本身**。文件始终保留原始版本，
-- 状态只用于界面提示与后续补处理。

CREATE TABLE media_jobs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_key     text NOT NULL,
  mime          text NOT NULL,
  status        text NOT NULL DEFAULT 'pending',
  reason        text,
  attempts      int  NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT media_jobs_status_check
    CHECK (status IN ('pending', 'processing', 'done', 'skipped', 'failed'))
);

CREATE INDEX media_jobs_status_idx ON media_jobs(status, created_at);
CREATE UNIQUE INDEX media_jobs_user_media_idx ON media_jobs(user_id, media_key);
