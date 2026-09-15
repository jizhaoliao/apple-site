#!/usr/bin/env node
// server.mjs — 用官方 workerd 跑我们的 Worker bundle，并对外提供 HTTP 服务。
//
// 为什么不直接写 workerd.capnp 静态文件：
// workerd 的 socket 配置需要绝对路径（disk path / module path），而容器里
// 工作目录可能变。用脚本在启动时生成 capnp，可以把路径算准，也方便把
// settings 暴露成环境变量。
//
// 为什么不用 miniflare：
// miniflare 是 wrangler 的内部运行时，它的 Node API（options schema）跨版本
// 变动频繁。直接用 workerd + 自己写 capnp 只依赖 workerd 的稳定协议，
// 升级 workerd 不会因为上层封装改 API 而崩。

import { spawn } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---- 可调参数（全部走环境变量） ----
const PORT = Number(process.env.PORT || 8787);
const BIND = process.env.BIND || "*";
const ENTRY_MODULE = process.env.ENTRY_MODULE || "worker.js";
const COMPAT_DATE = process.env.COMPATIBILITY_DATE || "2026-08-05";
const COMPAT_FLAGS = (process.env.COMPATIBILITY_FLAGS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const SOCKET_NAME = "http";
// workerd 的 socket 名只是给 --socket-addr 覆盖用的标识符，取个好认的即可。
// 注意：BIND 用 "*" 而不是 "0.0.0.0"，这是 KJ parseAddress 的官方通配写法，
// 能同时监听 IPv4 和 IPv6；写 "0.0.0.0" 只有 IPv4，某些网络环境下解析会出怪问题。

const modulePath = resolve(__dirname, ENTRY_MODULE);
if (!existsSync(modulePath)) {
  console.error(`[server] 找不到 worker bundle: ${modulePath}`);
  console.error(`[server] 先跑 node build.mjs 生成，或用 ENTRY_MODULE= 指定文件名`);
  process.exit(1);
}

const workerdBin = process.env.WORKERD_BIN || "workerd";

// ---- capnp 字符串转义 ----
// capnp 的 text 字面量会处理反斜杠和引号，Windows 路径的反斜杠必须转义，
// 否则 workerd 会把 \U 之类当成非法转义序列直接报错。
const esc = (s) => String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"');

const flagsLine = COMPAT_FLAGS.length
  ? `        compatibilityFlags = [${COMPAT_FLAGS.map((f) => `"${esc(f)}"`).join(", ")}],\n`
  : "";

// ---- 生成 capnp ----
// 结构说明（字段名严格对应 workerd.capnp 的 schema）：
//   sockets   -> 定义监听地址。union 里必须选一个协议分支，http = () 表示"这是一个
//                HTTP socket"。漏写这个分支 capnp 校验会直接失败。
//   services  -> 定义一个 worker 服务。worker.modules 是个 List(Module)，列表里
//                第一个模块即主模块（导出 fetch 的那个）。
//   config    -> 把 socket 绑到 service，worker 才会真正被请求驱动。
//
// 模块按 esModule 声明。因为 build.mjs 已经 bundle 过了，这里只需要一个模块文件，
// 不再有依赖解析问题 —— 这也是为什么容器里不需要 node_modules。
const capnp = `# 本文件由 server.mjs 自动生成，请勿手工修改
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    ( name = "main",
      worker = (
        modules = [
          ( name = "${esc(ENTRY_MODULE)}",
            esModule = embed "${esc(modulePath)}" )
        ],
        compatibilityDate = "${esc(COMPAT_DATE)}",
${flagsLine}      )
    )
  ],

  sockets = [
    ( name = "${esc(SOCKET_NAME)}",
      address = "${esc(BIND)}:${PORT}",
      # http = () 不能省：Socket 的协议分支是个 union，不选就等于没声明协议类型
      http = (),
      service = "main" )
  ]
);
`;

const capnpPath = resolve(__dirname, "workerd.generated.capnp");
writeFileSync(capnpPath, capnp, "utf8");

console.log(`[server] capnp   -> ${capnpPath}`);
console.log(`[server] bundle  -> ${modulePath}`);
console.log(`[server] 监听    -> http://${BIND}:${PORT}`);
console.log(`[server] workerd -> ${workerdBin}`);

// ---- 启动 workerd ----
// 用 spawn + 继承 stdio，把 workerd 的日志直接透出来，
// 这样 docker logs 里能看到请求日志和启动错误。
const args = ["serve", capnpPath];

// workerd 默认只监听 127.0.0.1；容器里要对外提供服务，必须显式绑到所有网卡。
// 用 --socket-addr 覆盖 capnp 里的地址，比改文件更直观。
// 注意 workerd 自带的 bin/workerd 是个 node wrapper，真正的二进制在
// @cloudflare/workerd-<platform> 包里，两者命令行参数一致。
if (process.env.ENABLE_INSPECTOR === "1") {
  args.push("--inspector-addr=127.0.0.1:9229");
}
if (process.env.VERBOSE === "1") {
  args.push("--verbose");
}

const child = spawn(workerdBin, args, {
  stdio: "inherit",
  env: process.env,
});

child.on("error", (err) => {
  console.error(`[server] 无法启动 workerd: ${err.message}`);
  console.error(`[server] 确认 workerd 已安装且在 PATH 里，或用 WORKERD_BIN= 指定绝对路径`);
  process.exit(1);
});

// workerd 的启动失败（capnp 语法错、端口占用、模块解析失败）都表现为
// 立刻非 0 退出。这里把最常见的几种原因翻译成人话，省得对着
// "capnp decode error" 之类的原始报错猜。
child.on("exit", (code, signal) => {
  if (code !== 0 && !signal && !child.__seenOutput) {
    console.error("");
    console.error("[server] workerd 启动失败，常见原因：");
    console.error("  1. capnp 语法/字段名与当前 workerd 版本不匹配");
    console.error("     -> workerd 升级后 schema 变更，检查 server.mjs 里的 capnp 模板");
    console.error(`  2. 端口 ${PORT} 已被占用 -> 换 PORT 或释放端口`);
    console.error("  3. bundle 里有未解析的裸导入 -> 重新跑 build.mjs");
    console.error("  4. 模块路径不可读 -> 确认 worker.js 已 COPY 进镜像");
    console.error("");
  }
  console.log(`[server] workerd 退出 code=${code} signal=${signal}`);
  process.exit(code ?? 1);
});

// 标记 workerd 是否已经输出过内容（有任何输出说明它至少开始跑了，
// 多半不是启动期错误），用于上面那个错误提示的判定。
child.stdout?.on("data", () => {
  child.__seenOutput = true;
});
child.stderr?.on("data", () => {
  child.__seenOutput = true;
});

// 把容器的停止信号转发给 workerd，保证 docker stop 能干净退出
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => child.kill(sig));
}
