#!/bin/sh
# 容器启动脚本：等数据库就绪 → 跑迁移 → 启动服务
set -eu

echo "[entrypoint] 等待数据库…"
i=0
until pg_isready -h "$(echo "$RJJ_DATABASE_URL" | sed -E 's#.*@([^:/]+).*#\1#')" -p "$(echo "$RJJ_DATABASE_URL" | sed -E 's#.*:([0-9]+)/.*#\1#')" -U "$(echo "$RJJ_DATABASE_URL" | sed -E 's#.*://([^:@]+).*#\1#')" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "[entrypoint] 数据库 60 秒内未就绪，退出" >&2
    exit 1
  fi
  sleep 1
done
echo "[entrypoint] 数据库已就绪"

echo "[entrypoint] 执行数据库迁移…"
node --import tsx src/db/migrate.ts

echo "[entrypoint] 启动服务：$*"
exec "$@"
