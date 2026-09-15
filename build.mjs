// build.mjs — 把 Worker 源码打成单文件 ESM bundle
//
// 为什么要打包：src/index.js 里 `import { Hono } from "hono/tiny"` 是裸模块说明符，
// workerd 自己不做 node_modules 解析（那是 wrangler/esbuild 的活）。所以必须先把
// hono 内联进来，产出一个自包含的 .js，运行镜像里就完全不需要 node_modules。
//
// 注意 workerd 的 ESM 解析规则：bundle 里不能留任何裸导入，否则启动即报
// "Could not resolve 'xxx'"。esbuild 的 --bundle 正好保证这一点。
//
// 默认值按「本文件在 <仓库根>/docker/ 下」设计：源码就是仓库根目录本身。

import { build } from "esbuild";
import { mkdirSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// 本文件位于 <仓库根>/docker/build.mjs，所以仓库根是它的上一级目录。
// 这样不论从哪个工作目录调用，路径都能算对。
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

const SRC = process.env.SRC_DIR || REPO_ROOT;
const OUT = process.env.OUT_FILE || resolve(REPO_ROOT, "dist/worker.js");

const entry = resolve(SRC, "src/index.js");
if (!existsSync(entry)) {
  console.error(`[build] 找不到入口文件: ${entry}`);
  console.error(`[build] 请用 SRC_DIR=<仓库根路径> 指定源码目录`);
  process.exit(1);
}

mkdirSync(dirname(resolve(OUT)), { recursive: true });

const result = await build({
  entryPoints: [entry],
  outfile: resolve(OUT),
  bundle: true,
  format: "esm",
  // workerd 支持到 es2022；target 设低一点没有副作用，只是少用些新语法糖
  target: "es2022",
  // 平台保持 neutral，避免 esbuild 把 node 内置模块当成外部依赖
  platform: "neutral",
  // mainFields 指定 browser 优先，确保 hono 走 Web 标准分支而不是 node 分支
  mainFields: ["module", "browser", "main"],
  conditions: ["worker", "browser", "import"],
  // --minify 与 wrangler deploy --minify 对齐，产物更小
  minify: true,
  // 保留 legal comment（依赖 licenses），其余注释去掉
  legalComments: "inline",
  metafile: true,
  logLevel: "info",
});

const bytes = Object.values(result.metafile.outputs)[0]?.bytes ?? 0;
console.log(`[build] 完成 -> ${OUT} (${(bytes / 1024).toFixed(1)} KB)`);
console.log(`[build] 提示: bundle 已内联所有依赖，运行镜像无需 node_modules`);
