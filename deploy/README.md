# Linux 部署（容器与原生两种）

> **状态说明**：本目录下的产物已通过 `docker compose config` 语法校验，
> 但**没有在真实 Linux 主机上完整跑通过**——开发环境是 Windows，且本机的
> Docker 守护进程因缺少 WSL 发行版无法启动。请把本文档当作"可执行的计划"，
> 而不是"已验证的说明书"。首次部署请预留排错时间。

## 方式一：Docker Compose（推荐）

```bash
# 1. 装 Docker（Ubuntu）
curl -fsSL https://get.docker.com | sh

# 2. 准备配置
cd RiJi
cp deploy/.env.example deploy/.env
# 编辑 deploy/.env：至少改 POSTGRES_PASSWORD 和 RJJ_JWT_SECRET
#   openssl rand -base64 32   ← 用它生成 JWT 密钥

# 3. 起服务
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build

# 4. 验证
curl http://127.0.0.1:8080/healthz
docker compose -f deploy/docker-compose.yml logs -f api
```

**预期结果**：`/healthz` 返回 `{"status":"ok",...}`；日志里能看到 `[migrate] applied ...`。

管理员初始密码在容器里：

```bash
docker compose -f deploy/docker-compose.yml exec api cat var/admin-initial-password.txt
```

### 端口说明

| 端口 | 用途 | 暴露范围 |
|---|---|---|
| 8080 | 客户端 API、管理后台 | 前面应加反向代理做 HTTPS |
| 9443 | 节点间 mTLS | **只对其他节点 IP 开放**，不要暴露公网 |
| 5432 | PostgreSQL | 只在 compose 内部网络，不映射到宿主机 |

### 加第二个节点

每个节点一份 compose（不同机器），副本节点改三处：

```dotenv
RJJ_NODE_ID=node-2
RJJ_NODE_ROLE=replica
RJJ_PRIMARY_URL=https://api-1.example.com:9443
```

并挂载证书目录：

```yaml
volumes:
  - /etc/riji/certs:/certs:ro
```

```dotenv
RJJ_TLS_DIR=/certs
```

证书生成见 [../docs/multi-node.md](../docs/multi-node.md)，命令是 `npm run certs`。

## 方式二：Linux 原生（不装 Docker）

```bash
sudo bash deploy/install-linux.sh
```

脚本会装 Node.js 22 + PostgreSQL、建库建用户、生成 `/etc/riji.env`、
注册 systemd 服务 `riji`，最后自检 `/healthz`。

同样**未在真实主机验证**。

## 方式三：Windows

见 [../docs/部署文档.md](../docs/部署文档.md)，或直接双击项目根目录的 `安装.bat`。

## 反向代理（强烈建议）

客户端要求 HTTPS。Caddy 最简单：

```
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy 会自动申请并续期 Let's Encrypt 证书。

## 备份

```bash
# 数据库
docker compose -f deploy/docker-compose.yml exec -T db \
  pg_dump -U riji -F c riji > riji-$(date +%F).dump

# 媒体
docker run --rm -v riji_media:/data -v "$PWD":/backup alpine \
  tar czf /backup/media-$(date +%F).tgz -C /data .
```

恢复：

```bash
docker compose -f deploy/docker-compose.yml exec -T db \
  pg_restore -U riji -d riji --clean --if-exists < riji-2026-08-01.dump
```

## 已知未验证点

| 项 | 说明 |
|---|---|
| 镜像构建 | Dockerfile 未实际 `docker build` 过（本机 Docker 守护进程无法启动：缺 WSL 发行版） |
| **已部分验证** | 服务端以容器用的那套环境变量（`RJJ_HOST=0.0.0.0`、`RJJ_MEDIA_DIR` 外置、`NODE_ENV=production`）在 Windows 上实跑通过：`/healthz` 200、监听 0.0.0.0、`/admin` 可访问、迁移自动执行 |
| Postgres 版本 | compose 用 16-alpine；本机开发用的是 17 |
| systemd 脚本 | 未在 Ubuntu/Rocky 上执行过 |
| SELinux | Rocky 系挂载卷需要 `:z` 标签，脚本未处理 |
| 时钟同步 | 需求 10.3 要求 chrony，脚本未安装与校验 |
