-- 0005_key_wrap.sql —— 主密钥与密码解耦
--
-- 做法：客户端生成一个随机主密钥（真正加密数据的钥匙），
-- 再用「密码 + 盐派生出的 KEK」把主密钥加密后存到服务端。
--
-- 好处：
--   * 改密码只需重新包裹主密钥，历史数据不用重新加密
--   * 新设备登录时拉取包裹体、解开即得同一把主密钥
--   * 服务端只有包裹体，没有 KEK，依然读不到主密钥

ALTER TABLE users ADD COLUMN key_wrap text;
ALTER TABLE users ADD COLUMN key_wrap_nonce text;
ALTER TABLE users ADD COLUMN key_wrap_version int NOT NULL DEFAULT 1;
