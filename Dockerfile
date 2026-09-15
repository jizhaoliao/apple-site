# ============================================================================
# apple-site (wloc-spoofer) — 自托管 Docker 镜像
#
# 两阶段构建：
#   stage 1 (builder) — 用 esbuild 把 Worker 源码打成单文件 bundle
#   stage 2 (runtime) — 只装 workerd + 那一个 bundle，不带 node_modules
#
# 保持上游代码零改动：跑的就是 Cloudflare 上的同一份 src/、同一个 workerd 运行时。
# ============================================================================

# ---------------------------------------------------------------------------
# stage 1: 构建
# ---------------------------------------------------------------------------
FROM node:22-alpine AS builder

WORKDIR /build

# 先只拷依赖清单，利用 Docker 层缓存：改源码不会触发重新装包
COPY package.json package-lock.json* ./
# 装运行期依赖（hono）+ 构建期依赖（esbuild）。
#
# esbuild 单独装而不写进 package.json，是为了**不改上游仓库文件**。
# 它是纯构建期工具，进不了最终镜像，所以放在这里装最合适。
RUN npm install --no-audit --no-fund \
 && npm install --no-save --no-audit --no-fund esbuild@^0.25.0

# 构建脚本
COPY docker/build.mjs ./

# 上游源码（只用 src/，其余与自托管无关）
COPY src/ ./src/

# 打包成单文件 bundle
ENV SRC_DIR=/build
ENV OUT_FILE=/build/dist/worker.js
RUN node docker/build.mjs

# 自检：bundle 里绝不能残留裸模块导入，否则 workerd 启动会失败。
# 放在构建期拦住，而不是等容器起来才报 "Could not resolve"。
RUN node -e "\
const s=require('fs').readFileSync('/build/dist/worker.js','utf8');\
const re=/(?:^|[;{}\s])import\s*(?:[\w*{][^;]*?from\s*)?['\"]([^.'\"][^'\"]*)['\"]/g;\
const bad=new Set();let m;\
while((m=re.exec(s))){bad.add(m[1]);}\
if(bad.size){console.error('[check] bundle 残留裸导入:',[...bad].join(', '));process.exit(1);}\
console.log('[check] bundle 无裸导入，OK');\
"

# ---------------------------------------------------------------------------
# stage 2: 运行
# ---------------------------------------------------------------------------
FROM node:22-alpine AS runtime

# workerd 由 npm 包分发（自带平台二进制）。
# 版本策略：锁到 1.2026 这条日期线，允许补丁位浮动。
#   完全锁死（=x.y.z）最可复现，但 npm 撤包后构建会失败；
#   完全不锁（latest）某天会因 capnp schema 变更而坏掉。折中处理。
RUN npm install -g workerd@~1.20260911.1 --no-audit --no-fund \
 && npm cache clean --force \
 && rm -rf /root/.npm /tmp/*

WORKDIR /app

# 只带运行必需的两个文件
COPY docker/server.mjs ./server.mjs
COPY --from=builder /build/dist/worker.js ./worker.js

ENV PORT=8787 \
    BIND="*" \
    ENTRY_MODULE=worker.js \
    COMPATIBILITY_DATE=2026-08-05 \
    NODE_ENV=production

EXPOSE 8787

# 健康检查用 node 自带的 fetch，不依赖镜像里有 curl/wget（alpine 默认没有）
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.mjs"]
