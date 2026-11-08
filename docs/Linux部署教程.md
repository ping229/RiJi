# Linux 部署教程（从零到能用）

面向：一台全新的 Ubuntu / Debian VPS，只有 root 或 sudo 权限。
目标：服务端跑起来，浏览器能打开管理后台，客户端能登录。

> 本文的命令都在 Ubuntu 22.04 / 24.04 上验证过流程；**具体某台 VPS 的网络策略以厂商为准**。

---

## 0. 先确认三件事

```bash
uname -a                       # 确认是 Linux x86_64
cat /etc/os-release            # 确认发行版（apt 系 / dnf 系）
free -m && df -h /             # 内存 ≥ 1G、磁盘 ≥ 10G 比较稳妥
```

需要：**Node.js 22+**、**PostgreSQL 14+**、一个**未被占用的端口**。

---

## 1. 端口怎么选（重要）

服务端默认 `8080`，但**完全可以自定义**，通过环境变量 `RJJ_PORT` 控制。

### 1.1 有些 VPS 厂商封端口怎么办

常见情况：只放行 80/443，或者只放行控制台"安全组"里勾选的端口。

三种解法，任选其一：

**方案 A：直接换端口（最简单）**

```bash
# 比如用 18080
RJJ_PORT=18080
```

同时记得：
- 云厂商控制台的**安全组/防火墙**要放行这个端口
- 服务器本机防火墙（ufw/firewalld）也要放行：

```bash
ufw allow 18080/tcp          # Ubuntu/Debian
firewall-cmd --add-port=18080/tcp --permanent && firewall-cmd --reload   # CentOS/Rocky
```

**方案 B：用 80/443 + 反向代理（推荐对外服务）**

服务端只监听本机 `127.0.0.1:8080`，由 Nginx/Caddy 对外提供 80/443。好处是能加 HTTPS，客户端里地址也更清爽。

```bash
RJJ_HOST=127.0.0.1
RJJ_PORT=8080
```

Caddy 配置（自动申请证书）：

```
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

**方案 C：先用高位端口在本地验证，再决定对外方式**

```bash
RJJ_PORT=18765
curl http://127.0.0.1:18765/healthz
```

### 1.2 端口优先级

| 变量 | 默认 | 说明 |
|---|---|---|
| `RJJ_PORT` | 8080 | 对外 API 端口 |
| `RJJ_HOST` | 0.0.0.0 | 监听地址；反向代理时建议 127.0.0.1 |
| `RJJ_REPLICATION_PORT` | 9443 | 多节点 mTLS 端口（单机可不管） |

---

## 2. 安装依赖

### Ubuntu / Debian

```bash
apt-get update
apt-get install -y curl git postgresql postgresql-contrib

# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node -v && npm -v
```

### Rocky / CentOS 系

```bash
dnf install -y git postgresql-server postgresql-contrib
dnf install -y https://rpm.nodesource.com/pub_22/x86_64/nodesource-release-el9-1.noarch.rpm
dnf install -y nodejs
postgresql-setup --initdb
```

可选：`apt-get install -y ffmpeg`（有它才能自动转码不兼容的视频格式）

---

## 3. 准备数据库

```bash
systemctl enable --now postgresql

# 建用户和库（自己换一个强密码）
sudo -u postgres psql -c "CREATE ROLE riji LOGIN PASSWORD '换成你的强密码';"
sudo -u postgres createdb -O riji riji
```

验证：

```bash
psql "postgres://riji:你的密码@127.0.0.1:5432/riji" -c "select 1;"
```

> 数据库只监听 `127.0.0.1` 就够，**不要**对公网开放 5432。

---

## 4. 拿到代码

```bash
mkdir -p /opt/riji && cd /opt/riji

# 方式一：git clone（仓库里已有全部源码）
git clone https://github.com/<你的用户名>/<仓库名>.git .

# 方式二：本地上传
#   本地执行：tar -czf riji.tar.gz server admin
#   上传解压：tar -xzf riji.tar.gz -C /opt/riji
```

确认目录结构：

```
/opt/riji/server     服务端
/opt/riji/admin      管理后台静态页
```
（`admin` 目录必须在 `server` 的兄弟位置，服务端按相对路径找它）

---

## 5. 安装依赖并配置

```bash
cd /opt/riji/server
npm install --no-audit --no-fund      # 内含 tsx，运行时需要
```

写环境变量文件：

```bash
cat > /etc/riji.env <<'EOF'
# 端口：换成你想用的（见第 1 节）
RJJ_PORT=8080
RJJ_HOST=0.0.0.0

# 数据库
RJJ_DATABASE_URL=postgres://riji:你的密码@127.0.0.1:5432/riji

# 媒体文件存放目录
RJJ_MEDIA_DIR=/var/lib/riji/media

# JWT 密钥：必须换成随机值！
# 生成：openssl rand -base64 48
RJJ_JWT_SECRET=换成随机字符串

# 节点身份
RJJ_NODE_ID=node-1
RJJ_NODE_ROLE=primary

# 业务规则（一般不用改）
RJJ_DAY_CUT_HOUR=4
RJJ_WRITE_WINDOW_DAYS=7

# 新用户默认配额（GB），0 表示不限制
RJJ_DEFAULT_QUOTA_GB=5
EOF

chmod 600 /etc/riji.env       # 里面有密码，收权限
mkdir -p /var/lib/riji/media
```

---

## 6. 用 systemd 托管

```bash
cat > /etc/systemd/system/riji.service <<'EOF'
[Unit]
Description=RiJi diary server
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
EnvironmentFile=/etc/riji.env
WorkingDirectory=/opt/riji/server
ExecStart=/usr/bin/npx tsx src/index.ts
Restart=always
RestartSec=5
StandardOutput=append:/var/log/riji.log
StandardError=append:/var/log/riji.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now riji
systemctl status riji --no-pager
```

首次启动会自动建表，并创建管理员账号，密码打印在日志与
`/opt/riji/server/var/admin-initial-password.txt`：

```bash
grep -A3 '管理员' /var/log/riji.log | tail -5
```

---

## 7. 验证

```bash
# 本机自检
curl http://127.0.0.1:8080/healthz
# => {"status":"ok","nodeId":"node-1","role":"primary",...}

# 管理后台
curl -I http://127.0.0.1:8080/admin

# 从外部访问（把端口换成你实际用的）
curl http://<服务器公网IP>:8080/healthz
```

外部访问不通时按顺序查：

1. `ss -lntp | grep 8080` —— 服务是否真的在监听
2. `ufw status` / `firewall-cmd --list-ports` —— 本机防火墙
3. 云厂商控制台的安全组 —— 最常见的原因
4. `curl http://127.0.0.1:8080/healthz` —— 本机通、外部不通 = 网络层问题

---

## 8. 客户端怎么连

Windows 客户端登录页「服务器地址」填：

```
http://<公网IP>:<你选的端口>
```

例如 `http://<你的服务器IP>:<你的端口>`。

手机同理，但注意手机和服务器要能互通；如果服务器在公网，直接用公网地址即可。

登录后：
1. 立刻改密码（主页 ⋮ → 修改密码）
2. 设置恢复短语（同一菜单，抄在纸上）
3. 跑一遍「自检」，确认六项正常

---

## 9. 反向代理与 HTTPS（建议）

```bash
apt-get install -y caddy
cat > /etc/caddy/Caddyfile <<'EOF'
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
EOF
systemctl enable --now caddy
```

然后把 `/etc/riji.env` 改成 `RJJ_HOST=127.0.0.1` 并 `systemctl restart riji`，
客户端地址改为 `https://api.example.com`。

---

## 10. 日常运维

```bash
systemctl restart riji                  # 重启
tail -f /var/log/riji.log               # 看日志
journalctl -u riji -n 100 --no-pager    # 系统日志

# 备份
sudo -u postgres pg_dump -F c riji > /root/riji-$(date +%F).dump
tar czf /root/media-$(date +%F).tgz -C /var/lib/riji/media .

# 升级（拉新代码后）
cd /opt/riji && git pull
cd server && npm install --no-audit --no-fund
systemctl restart riji
```

升级重启时会自动应用新的数据库迁移（`server/migrations/`）。

---

## 11. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `ECONNREFUSED 127.0.0.1:5432` | PostgreSQL 没起，或连接串密码错 |
| 启动报 `缺少 RJJ_JWT_SECRET` | `/etc/riji.env` 没写或 systemd 没读到 |
| 外部访问 502/超时 | 安全组没放行；或 `RJJ_HOST` 写成了 127.0.0.1 |
| `/admin` 404 | `admin/` 目录没和 `server/` 放在同一级 |
| 上传大文件失败 | 反向代理的 body 限制（Nginx `client_max_body_size 600m;`） |
| 空间不足 | 管理员后台调高该用户配额，或删媒体 |
| 服务反复重启 | `tail -50 /var/log/riji.log` 看真实报错 |

---

## 12. 多节点（可选）

见 [multi-node.md](multi-node.md)。要点：

- 第二台机器用**独立的数据库**
- `RJJ_NODE_ROLE=replica`、`RJJ_PRIMARY_URL` 指向主节点
- 节点间建议启用 mTLS（`RJJ_TLS_DIR`，端口 `RJJ_REPLICATION_PORT`，默认 9443——同样可以自定义）

---

## 附：用 Docker 部署

见 [../deploy/README.md](../deploy/README.md)。端口在 `deploy/.env` 的 `RJJ_PORT` 里改。
