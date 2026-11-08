# VPS 部署记录

部署时间：2026-11-05
最近更新：**2026-11-08**（升级到今天的最新代码 + 轮换管理员口令）
服务器：`<你的服务器IP>`（Ubuntu 24.04，4G 内存，62G 可用）
状态：**已上线可用**

## 访问地址

| 用途 | 地址 |
|---|---|
| 健康检查 | http://<你的服务器IP>:<你的端口>/healthz |
| 管理后台 | http://<你的服务器IP>:<你的端口>/admin |
| 客户端登录 | 服务器地址填 `http://<你的服务器IP>:<你的端口>` |

管理员账号：`admin`。密码**不写在文档里**：
- 服务器本机：`/root/riji-admin-password.txt`（权限 600，只有 root 能读）
- 旧口令（曾在文档里明文出现）已于 2026-11-08 作废，实测返回 401

> 轮换是"重包裹主密钥"方式做的（`server/scripts/rewrap-password.mjs`），
> 主密钥没变，所以 admin 名下的历史日记仍然可读。实测新旧主密钥一致。
> 如果哪天又要改：优先在客户端里改（主页 ⋮ → 修改密码）；没有客户端时用这个脚本。

## 服务器上的东西在哪

| 内容 | 路径 |
|---|---|
| 程序代码 | `/opt/riji/server` |
| 管理后台静态页 | `/opt/riji/admin` |
| 环境变量（含数据库密码、JWT 密钥） | `/etc/riji.env`（权限 600） |
| 媒体文件 | `/var/lib/riji/media` |
| 运行日志 | `/var/log/riji.log` |
| systemd 服务 | `riji.service` |

## 常用运维命令

```bash
systemctl status riji      # 看状态
systemctl restart riji     # 重启
journalctl -u riji -n 50   # 看日志（或 tail -f /var/log/riji.log）
```

## 数据库

- PostgreSQL 16，监听 `127.0.0.1:5432`（**不对外暴露**）
- 库名 `riji`，用户 `riji`，密码在 `/etc/riji.env` 的 `RJJ_DATABASE_URL` 里
- 备份：

```bash
sudo -u postgres pg_dump -F c riji > /root/riji-$(date +%F).dump
```

## 关于 HTTPS

现在走的是 HTTP。日记内容在客户端已加密，传输的是密文，但仍建议加一层 TLS：

```bash
apt-get install -y caddy
cat > /etc/caddy/Caddyfile <<'EOF'
api.your-domain.com {
    reverse_proxy 127.0.0.1:<你的端口>
}
EOF
systemctl enable --now caddy
```

有域名后 Caddy 会自动申请证书，然后把客户端里的服务器地址改成 `https://api.your-domain.com`。

## 重新部署（改了服务端代码后）

```powershell
# 本地打包：只带代码，别带 node_modules 与 var（var 里可能有口令文件）
tar -czf $env:TEMP\riji-deploy.tgz --exclude=server/node_modules --exclude=server/var --exclude=server/test server admin
pscp -pw <密码> $env:TEMP\riji-deploy.tgz root@<你的服务器IP>:/tmp/
```

```bash
# 服务器上：先备份，再解压到 /opt/riji（注意是 /opt/riji，不是 /opt——解到 /opt 会生成 /opt/server，等于没更新）
cd /opt && tar -czf /root/riji-backup-$(date +%Y%m%d-%H%M%S).tgz riji
tar -xzf /tmp/riji-deploy.tgz -C /opt/riji
cd /opt/riji/server && npm install --no-audit --no-fund   # package.json 没变可跳过
systemctl restart riji && sleep 3
curl -s http://127.0.0.1:<你的端口>/healthz
```

部署后怎么确认"新代码真的在跑"（2026-11-08 新增的标记）：

```bash
grep -c toUserLogPayload /opt/riji/server/src/services/replication.ts   # 应为 1
test -f /opt/riji/server/src/services/retention.ts && echo YES          # 应为 YES
grep -c 'media/:key/meta' /opt/riji/server/src/routes/replication.ts    # 应为 1
```

2026-11-08 的备份：`/root/riji-backup-20261108-234801.tgz`（13MB，含升级前的旧代码）。
轮换口令前的用户行备份：`/root/admin-credentials-backup-*.json`（600，确认无误后可删）。

## 重置密码（分两种情况）

| 情况 | 用什么 |
|---|---|
| 账号**没有**端到端加密（`key_wrap` 为空） | `npx tsx scripts/set-password.ts <用户名> <新密码>` |
| 账号**已启用**加密（有 `key_wrap`） | 优先在客户端里改；没有客户端时用 `node scripts/rewrap-password.mjs <用户名>`（重包裹主密钥，历史数据不丢） |

`rewrap-password.mjs` 的口令用 base64 传，避免 shell 吃掉 `! $ *` 之类的字符：

```bash
set -a; . /etc/riji.env; set +a
OLD=$(printf '%s' '旧密码' | base64 -w0); NEW=$(printf '%s' '新密码' | base64 -w0)
cd /opt/riji/server
RJJ_OLD_PASS_B64=$OLD RJJ_NEW_PASS_B64=$NEW node scripts/rewrap-password.mjs admin
```

## 已知情况

- 服务器上有 ffmpeg，媒体归一化已自动启用
- 目前是单节点（primary）。要加副本参照 [multi-node.md](multi-node.md)
- <你的端口> 端口已能从公网访问；如果哪天不通了，先查云厂商安全组是否放行
