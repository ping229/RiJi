#!/usr/bin/env bash
# RiJi 服务端 · Linux 原生部署脚本（Ubuntu 22.04/24.04、Rocky 9）
#
# 用途：不装 Docker 的机器上，直接装 Node.js + PostgreSQL 并跑起来。
# 用法：
#   sudo bash deploy/install-linux.sh
#
# 注意：本脚本尚未在真实 Linux 主机上验证过（开发环境只有 Windows）。
# 执行前请先读一遍，确认每一步你都能接受。
set -euo pipefail

APP_DIR="/opt/riji"
DATA_DIR="/var/lib/riji"
DB_NAME="riji"
DB_USER="riji"
PORT="8080"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "请用 root 运行：sudo bash deploy/install-linux.sh"

# ---------------------------------------------------------------- 1. 依赖
log "检测发行版"
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  fail "只支持 apt 或 dnf 系发行版"
fi

log "安装 Node.js 22 与 PostgreSQL"
if [ "$PKG" = apt ]; then
  apt-get update -qq
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs postgresql postgresql-contrib curl
else
  dnf install -y https://rpm.nodesource.com/pub_22/x86_64/nodesource-release-el9-1.noarch.rpm
  dnf install -y nodejs postgresql-server postgresql-contrib curl
  postgresql-setup --initdb || true
fi

# ---------------------------------------------------------------- 2. 数据库
log "启动 PostgreSQL"
systemctl enable --now postgresql 2>/dev/null || systemctl enable --now postgresql-16 2>/dev/null || true

log "创建数据库与用户（已存在则跳过）"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '$(openssl rand -hex 16)';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

# ---------------------------------------------------------------- 3. 部署
log "准备目录 ${APP_DIR}"
mkdir -p "${APP_DIR}" "${DATA_DIR}/media"
if [ ! -d "${APP_DIR}/server" ]; then
  fail "请先把项目复制到 ${APP_DIR}（需要 server/ 目录）"
fi

log "安装服务端依赖"
cd "${APP_DIR}/server"
npm install --no-audit --no-fund

# ---------------------------------------------------------------- 4. 环境变量
log "写入环境变量 /etc/riji.env"
if [ ! -f /etc/riji.env ]; then
  cat > /etc/riji.env <<EOF
RJJ_PORT=${PORT}
RJJ_HOST=0.0.0.0
RJJ_DATABASE_URL=postgres://${DB_USER}:请改成数据库密码@127.0.0.1:5432/${DB_NAME}
RJJ_MEDIA_DIR=${DATA_DIR}/media
RJJ_JWT_SECRET=$(openssl rand -base64 32)
RJJ_NODE_ID=node-1
RJJ_NODE_ROLE=primary
EOF
  chmod 600 /etc/riji.env
  log "已生成 /etc/riji.env，注意里面的数据库密码需要与上面创建的一致"
fi

# ---------------------------------------------------------------- 5. 服务
log "创建 systemd 服务"
cat > /etc/systemd/system/riji.service <<EOF
[Unit]
Description=RiJi diary server
After=network.target postgresql.service

[Service]
Type=simple
EnvironmentFile=/etc/riji.env
WorkingDirectory=${APP_DIR}/server
ExecStart=/usr/bin/node --import tsx src/index.ts
Restart=always
RestartSec=5
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
EOF

chown -R www-data:www-data "${DATA_DIR}"
systemctl daemon-reload
systemctl enable --now riji

log "等待服务就绪"
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    log "服务已就绪：http://127.0.0.1:${PORT}/healthz"
    break
  fi
  sleep 1
done

log "完成"
echo
echo "  下一步："
echo "    1. 管理员初始密码：cat ${APP_DIR}/server/var/admin-initial-password.txt"
echo "    2. 管理后台：http://<服务器IP>:${PORT}/admin"
echo "    3. 对外提供 HTTPS 请在前面加 Caddy/Nginx 反向代理"
echo "    4. 查看日志：journalctl -u riji -f"
