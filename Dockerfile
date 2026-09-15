# ============================================================================
# apple-site (wloc-spoofer) — 自托管 Docker 镜像
#
# 两阶段构建：
#   stage 1 (builder) — 用 esbuild 把 Worker 源码打成单文件 bundle
#   stage 2 (runtime) — 只装 workerd + 那一个 bundle，不带 node_modules
#
# 保持上游代码零改动：跑的就是 Cloudflare 上的同一份 src/、同一个 workerd 运行时。
#
# ⚠️ 基础镜像必须用 Debian，不能用 Alpine。
#    workerd 的官方二进制是链接 glibc + libc++ 的，而 Alpine 是 musl libc，
#    且 Alpine 仓库里没有 libc++ 包。Cloudflare 维护者明确说过 workerd 在
#    Alpine 上"不容易跑起来"。（见 cloudflare/workerd issue #286）
#    踩坑记录：用 Alpine 时 npm install 会**成功**（因为平台包没声明 libc 字段，
#    不会被过滤），但装下来的是跑不了的 glibc 二进制，且 postinstall 的
#    版本校验失败时只打印警告、不返回非 0 —— 结果就是镜像构建"绿"的、
#    容器一起来就 `spawn workerd ENOENT`。构建期看不懂，运行期才炸。
# ============================================================================

# ---------------------------------------------------------------------------
# stage 1: 构建
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS builder

WORKDIR /build

# 先只拷依赖清单，利用 Docker 层缓存：改源码不会触发重新装包
COPY package.json package-lock.json* ./
# 装运行期依赖（hono）+ 构建期依赖（esbuild）。
#
# esbuild 单独装而不写进 package.json，是为了**不改上游仓库文件**。
# 它是纯构建期工具，进不了最终镜像，所以放在这里装最合适。
RUN npm install --no-audit --no-fund \
 && npm install --no-save --no-audit --no-fund esbuild@^0.25.0

# 构建脚本。
# ⚠️ 必须保持 docker/ 这一层目录结构，不能拍平成 ./build.mjs。
# 原因有两个：
#   1) 下面的执行命令是 `node docker/build.mjs`，路径要能对上
#   2) build.mjs 内部用 `resolve(__dirname, "..")` 推算仓库根目录
#      （因为它假定自己在 <仓库根>/docker/ 下），拍平会让它算错路径
COPY docker/ ./docker/

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
FROM node:22-bookworm-slim AS runtime

# ---- 运行时依赖 ----
# libc++1 / libc++abi1 / libunwind8：workerd 二进制动态链接的 C++ 运行时。
#   C++ 协程需要 libc++（workerd 大量使用协程），缺了会直接 exec 失败。
# ca-certificates：workerd 要往 gs-loc.apple.com 发 HTTPS 请求，没证书会握手失败。
# tini：作为 PID 1 做信号转发 + 收割僵尸进程，配合下面的 ENTRYPOINT 使用。
# --no-install-recommends 避免拖进无用的推荐包，保持镜像精简。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libc++1 \
      libc++abi1 \
      libunwind8 \
      ca-certificates \
      tini \
 && rm -rf /var/lib/apt/lists/*

# workerd 由 npm 包分发（自带平台二进制，在 @cloudflare/workerd-linux-64 里）。
# 版本策略：锁到 1.2026 这条日期线，允许补丁位浮动。
#   完全锁死（=x.y.z）最可复现，但 npm 撤包后构建会失败；
#   完全不锁（latest）某天会因 capnp schema 变更而坏掉。折中处理。
RUN npm install -g workerd@~1.20260911.1 --no-audit --no-fund

# ⚠️ 构建期自检（这一步是本 Dockerfile 最重要的防线之一）
# 上面说了，workerd 的 postinstall 在二进制跑不起来时**只警告不报错**，
# 所以 `npm install` 成功 ≠ 二进制可用。这里主动执行一次 --version，
# 让平台/依赖错配在构建期就变成红色失败，而不是等到 NAS 上容器起不来。
RUN workerd --version \
 && echo "[check] workerd 二进制可执行，OK"

# 清 npm 缓存。注意：必须在 workerd 自检**之后**再清，别把二进制误删。
RUN npm cache clean --force && rm -rf /root/.npm

WORKDIR /app

# 只带运行必需的两个文件
COPY docker/server.mjs ./server.mjs
COPY --from=builder /build/dist/worker.js ./worker.js

# 预建可挂载目录。
# 目的：让 docker-compose 里的 ./data:/app/data 和 ./logs:/app/logs
# 在**镜像层面**就有对应路径。若不预建，Docker 首次 up 时也会自动创建，
# 但那是「空目录覆盖」—— 万一以后镜像里要放默认数据/配置，会被直接盖掉。
# 这里显式建好并给足权限，语义更清晰。
RUN mkdir -p /app/data /app/logs \
 && chmod 755 /app/data /app/logs

ENV PORT=8787 \
    BIND="*" \
    ENTRY_MODULE=worker.js \
    COMPATIBILITY_DATE=2026-08-05 \
    NODE_ENV=production

# ⚠️ 构建期第二道自检：预检 capnp 与 embed 路径
#
# 踩过的坑：capnp 的 embed 对以 "/" 开头的路径**不当文件系统绝对路径**处理，
# 而是去 -I 搜索路径（workerd 自带 builtin 目录）里找，于是报
#   Couldn't read file for embed: /app/worker.js
# 这类错误只有真跑起来才暴露。这里用 `workerd compile --config-only`
# 做一次纯解析预检（只解析不启动、不占端口），提前到构建期拦住。
#
# 注意 capnp 文件要放在 /app 下，这样 embed "worker.js" 才正好指向
# /app/worker.js —— 和生产环境完全一致的解析路径。
RUN printf '%s\n' \
      'using Workerd = import "/workerd/workerd.capnp";' \
      'const config :Workerd.Config = (' \
      '  services = [ ( name = "main", worker = (' \
      '    modules = [ ( name = "worker.js", esModule = embed "worker.js" ) ],' \
      '    compatibilityDate = "2026-08-05", ) ) ],' \
      '  sockets = [ ( name = "http", address = "*:8787", http = (), service = "main" ) ] );' \
      > /app/check.capnp \
 && workerd compile /app/check.capnp config --config-only > /app/check.bin \
 && rm -f /app/check.capnp /app/check.bin \
 && echo "[check] capnp 解析 + embed 相对路径读取，OK"

EXPOSE 8787

# 健康检查用 node 自带的 fetch，不依赖镜像里有 curl/wget
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# tini 做 PID 1：正确转发 SIGTERM 给 workerd，docker stop 才能干净退出
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.mjs"]
