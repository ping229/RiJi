# RiJi 服务端镜像
#
# 构建上下文是仓库根目录（不是 server/），因为要复制 server/ 整个目录。
#   docker build -f deploy/Dockerfile -t riji-server:0.1.0 .

FROM node:22-alpine AS deps
WORKDIR /app
COPY server/package.json server/package-lock.json* ./
# 运行时要执行 TypeScript（tsx），所以不能省略 devDependencies
RUN npm install --no-audit --no-fund

FROM node:22-alpine AS runtime
# tini 负责转发信号，让容器能优雅关闭
RUN apk add --no-cache tini curl postgresql-client
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY server/ ./
COPY deploy/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 非 root 运行；数据目录需要可写
RUN mkdir -p /data/media && chown -R node:node /data /app
USER node

ENV NODE_ENV=production \
    RJJ_HOST=0.0.0.0 \
    RJJ_PORT=8080 \
    RJJ_MEDIA_DIR=/data/media

EXPOSE 8080 9443
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${RJJ_PORT}/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "--import", "tsx", "src/index.ts"]
