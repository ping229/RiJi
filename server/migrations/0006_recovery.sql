-- 0006_recovery.sql —— 恢复短语
--
-- 想法：另外生成一把「恢复密钥」，用它把主密钥再包裹一份存在服务端。
-- 用户把恢复短语（16 个词）抄在纸上；忘记密码时用短语还原出恢复密钥，
-- 再由恢复密钥解出主密钥，然后设置新密码即可。
--
-- 服务端只有包裹体和恢复密钥的散列，两样都解不开主密钥。

ALTER TABLE users ADD COLUMN recovery_wrap text;
ALTER TABLE users ADD COLUMN recovery_nonce text;
ALTER TABLE users ADD COLUMN recovery_created_at timestamptz;
ALTER TABLE users ADD COLUMN recovery_proof text;
