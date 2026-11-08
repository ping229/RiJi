-- 0004_e2ee.sql —— 端到端加密所需的密钥派生盐
--
-- 盐只用于让相同密码在不同用户上派生出不同密钥，本身不是秘密。
-- 服务端存它，但永远拿不到由它派生出的密钥。

ALTER TABLE users ADD COLUMN kdf_salt text;
ALTER TABLE users ADD COLUMN kdf_iterations int NOT NULL DEFAULT 210000;
