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
# 本地打包
tar -czf riji-server.tar.gz -C <repo> server admin
# 上传
pscp -pw <密码> riji-server.tar.gz root@<你的服务器IP>:/tmp/
# 服务器上
tar -xzf /tmp/riji-server.tar.gz -C /opt/riji
cd /opt/riji/server && npm install --no-audit --no-fund
systemctl restart riji
```

## 已知情况

- 服务器上有 ffmpeg，媒体归一化已自动启用
- 目前是单节点（primary）。要加副本参照 [multi-node.md](multi-node.md)
- <你的端口> 端口已能从公网访问；如果哪天不通了，先查云厂商安全组是否放行
