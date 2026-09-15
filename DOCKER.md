# Docker 自托管（用 GitHub Actions 构建）

把本项目从 Cloudflare Pages/Workers 搬到自己的 NAS 上跑。

**镜像由 GitHub 的服务器构建** —— 所以你本地不需要装 Docker，NAS 上也不用跑耗时的构建。  
NAS 只负责 `docker pull` 拉取现成镜像。

---

## 一、整体流程

```
你点一下 Actions 按钮
        ↓
GitHub 机器：跑测试 → esbuild 打包 → 构建镜像 → 推 GHCR → 冒烟测试
        ↓
你的 NAS：docker compose pull && up -d
```

好处：

- **本机无需 Docker**：构建全在 GitHub 上完成
- **NAS 无构建负担**：不用下载 node 基础镜像、不用装 esbuild，只拉一个成品镜像
- **构建前有把关**：上游测试不过就不构建，坏镜像推不上去
- **推送后有验证**：CI 里真跑一次容器，确认能起来、接口正常才收工

---

## 二、一次性配置（只做一次）

### 1. 开启 Actions 写权限 ⚠️ 必做

**不开这个，构建会以 403 失败**，而且报错看起来像认证问题，很容易被误导。

> 仓库页面 → **Settings** → 左侧 **Actions** → **General** →  
> 滚到 **Workflow permissions** →  
> 选 **Read and write permissions** → **Save**

### 2. 确认 GHCR 包可见性（可选）

第一次构建完成后，镜像会出现在：  
`https://github.com/users/jizhaoliao/packages/container/apple-site`

默认继承仓库可见性。你的仓库是公开的，所以镜像也是公开的，NAS 拉取**不需要登录**。

> 想改成私有：Packages 页面 → 该包 → Package settings → Change visibility。  
> 改私有后 NAS 拉取要 `docker login ghcr.io`，见下面「私有镜像怎么办」。



---

## 三、构建镜像

1. 打开仓库的 **Actions** 标签页
2. 左侧选 **Build and push Docker image**
3. 右侧点 **Run workflow** 按钮
4. 参数说明：

| 参数         | 说明                            |
| ---------- | ----------------------------- |
| `tag`      | 自定义标签，留空则自动用 short SHA。一般留空即可 |
| `no_cache` | 依赖更新了但缓存没失效时勾选。平时不用勾          |

1. 点绿色 **Run workflow** 开始

构建大约 2–4 分钟（首次稍慢）。完成后点进那次运行，**Summary 页面**会直接给出镜像地址和 NAS 拉取命令。

每次构建会打三个标签：

- `latest` —— NAS 平时用的就是这个
- `<short SHA>` —— 想回退到某次具体构建时用
- 你填的自定义 tag（如果填了）

---

## 四、在 NAS 上部署

把本目录的 `docker-compose.yml` 拷到 NAS（比如 `/vol2/1000/docker/apple-site/`），然后：

```bash
cd /vol2/1000/docker/apple-site

# 拉取镜像
docker compose pull

# 启动
docker compose up -d

# 看日志
docker compose logs -f
```

### 验证

```bash
# 首页
curl -i http://127.0.0.1:8787/

# 坐标解析（高德/苹果地图链接，自动 GCJ-02 → WGS84）
curl "http://127.0.0.1:8787/api/parse?format=json&u=https%3A%2F%2Fmaps.apple.com%2F%3Fll%3D39.9042%2C116.4074%26name%3DTiananmen"
# 期望：{"lat":39.902796,"lon":116.401157,"name":"Tiananmen"}
# lat 从 39.9042 变成 39.902796 是正确行为（GCJ-02→WGS84 约 110 米偏移）
```

浏览器打开 `http://<NAS的IP>:8787/` 即可。

---

## 五、更新到新版本

代码有改动后：

```bash
# 1. 推代码到 GitHub
git push

# 2. 到 Actions 页面点一次 Run workflow

# 3. NAS 上拉新镜像并重启
cd /vol2/1000/docker/apple-site
docker compose pull && docker compose up -d
```

---

## 六、改端口 / 配置

编辑 `docker-compose.yml`：

| 项                    | 默认           | 说明                                |
| -------------------- | ------------ | --------------------------------- |
| `ports` 左侧           | `8787`       | NAS 上对外端口，冲突就改这里                  |
| `PORT`               | `8787`       | 容器内端口，与上面右侧保持一致                   |
| `BIND`               | `*`          | 监听所有网卡。**别改成 `0.0.0.0`**，那只管 IPv4 |
| `COMPATIBILITY_DATE` | `2026-08-05` | 与仓库 `wrangler.jsonc` 同步，改上游时一起改   |
| `logging`            | 10MB×3       | 日志轮转，防止写满 NAS 磁盘                  |

---

## 七、私有镜像怎么办

如果 GHCR 包设成了私有，NAS 拉取需要先登录：

```bash
# 需要一个有 read:packages 权限的 GitHub PAT（经典 token 或细粒度 token）
echo "<你的PAT>" | docker login ghcr.io -u jizhaoliao --password-stdin

docker compose pull
```

PAT 有效期到后需要重新登录。**建议保持包公开**（你的仓库本来就是公开的），  
省掉这层维护成本。

---

## 八、常见问题

| 现象                                                   | 原因                                            | 处理                                                                      |
| ---------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------- |
| Actions 报 `denied: permission_denied: write_package` | Workflow permissions 没开写权限                    | 见第二节第 1 步                                                               |
| Actions 报 `npm ci` 失败                                | 有 `package.json` 无 `package-lock.json`，或两者不同步 | 本地跑一次 `npm install` 提交 lock 文件；或把 workflow 里的 `npm ci` 改成 `npm install` |
| 上游测试用例失败                                             | `test/` 里可能有依赖未提交产物的用例                        | 见下方「关于 wloc-stash-output.test.js」                                       |
| NAS 上 `docker compose pull` 超时                       | ghcr.io 国内无 CDN                               | 见下节                                                                     |
| 容器起来就退出                                              | 多半是 workerd 的 capnp 问题                        | `docker compose logs`，脚本会给出人话版原因                                        |
| 页面能开但地图空白                                            | 页面依赖 unpkg CDN 的 Leaflet                      | 确认容器能出网                                                                 |

### 关于 `npm test` 的一个坑

`package.json` 里的测试脚本写的是 `node --test 'test/*.test.mjs'`，  
那个**单引号会让 shell 不展开 glob**，node 收到的是字面量字符串，结果是：

```
# tests 0
# pass 0
```

退出码是 **0** —— 看起来"通过了"，实际上**一个测试都没跑**。  
拿它当 CI 门禁等于没有门禁。所以 workflow 里没用 `npm test`，  
而是直接 `node --test test/parse.test.mjs`（22 个断言，全部通过）。

### 关于 `test/wloc-stash-output.test.js`

这个文件读 `dist/wloc.js`，但：

- 该文件**不在仓库里**（`dist/` 只有 `_routes.json`）
- **没有任何构建步骤生成它**（`package.json` 里没有对应脚本）
- `src/` 下也**没有任何 stash 相关代码**

是个失效测试，与本次改动无关，因此 CI 里排除了它。要彻底清理可以从仓库删掉。

### ghcr.io 拉取慢/超时

`ghcr.io` 在国内没有 CDN，这是已知痛点。几个办法：

1. **用代理拉取**：在 NAS 的 Docker 配置里给 daemon 配代理（fnOS 的 Docker 设置里有入口）
2. **中转**：找一台能访问的机器 `docker pull` 后 `docker save`，再传到 NAS `docker load`
3. **换仓库**：改用阿里云 ACR 等国内镜像仓库（要改 workflow 的登录和推送目标）

---

## 九、安全边界（重要）

代码里有一段注释值得注意：

> `/api/parse` 会去 fetch 调用方给的任意 URL。Workers 出网到不了内网，所以经典的  
> SSRF（打内网/元数据服务）基本不成立

**这个前提是 Cloudflare 平台给的，自托管后没有了。** 容器出网就是你的家庭网络。

代码里的 `isFetchable()` 已经挡掉了 `localhost`、`.local`、`.internal` 和 IP 字面量，  
但**域名形式的内网服务（如 `nas.home.lan`）不在黑名单里**。

**建议：**

- 只在内网使用（快捷指令、手机浏览器）
- **不要直接做公网端口映射**
- 真要从外网访问，套一层带认证的反向代理（Cloudflare Tunnel + Access，或 Nginx + Basic Auth）

---

## 十、文件说明

| 文件                                   | 作用                            |
| ------------------------------------ | ----------------------------- |
| `.github/workflows/docker-build.yml` | CI：构建镜像推 GHCR                 |
| `Dockerfile`                         | 两阶段构建：esbuild 打包 → workerd 运行 |
| `docker/build.mjs`                   | 把 Worker 源码打成单文件 bundle       |
| `docker/server.mjs`                  | 生成 workerd 配置并驱动其运行           |
| `docker-compose.yml`                 | NAS 侧部署配置（从 GHCR 拉取）          |
| `.dockerignore`                      | 减小构建上下文                       |
| `.gitattributes`                     | 防止 CRLF 破坏脚本                  |

### 上游代码零改动

`src/`、`functions/`、`wrangler*.jsonc`、`package.json` 全部保持原样。  
自托管相关的文件都是**新增**的，所以 CF 那边照常部署，两条路并行互不影响。

`esbuild` 只在 Dockerfile 里安装（`npm install --no-save`），没有写进 `package.json`。
