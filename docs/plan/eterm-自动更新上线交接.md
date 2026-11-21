# eterm · 自动更新上线交接（mac 构建机执行手册）

> 日期：2026-11-21 ｜ 基线：**fff2d7d**（三端自动更新代码已落地并推送，工作区干净）
> 读者：在 mac 构建机上操作的人。前置阅读 [AGENTS.md](../../AGENTS.md)；设计细节见 [eterm-自动更新方案.md](eterm-自动更新方案.md)（v1.2，含 §11 验收顺序与 §12 风险登记）。
> 本文档是**可勾选的执行清单**，按 A→F 顺序做；B 是三端发布的共同解锁项。

---

## 0. 现状快照（交接时点）

| 项 | 状态 |
|---|---|
| 代码 | 三端自动更新 + 三个发布脚本 + nginx conf 已提交（fff2d7d）；`flutter analyze` 0 error/warning、`flutter test` 71、`cargo test --lib` 22 全绿 |
| pubspec | 仍为 `1.0.0+1`（**任何一端都还没跑过真实脚本发布**） |
| 生产 nginx | **无 `/updates/` location**（/updates/* 会被 proxy 给中枢 → 404） |
| 服务端 | 11-20 出过"生产滞后三个 commit"事故（客户端改密码 404），**之后是否重新部署过需现场确认** |
| Windows 机 | 11-21 探测发现 **pem 密钥不在 Windows 机**（`~/Downloads/_my-aliyun-ecs-2026.pem` 缺失）——Windows 发布前必须解决（任务 E） |
| 服务器磁盘 | ~86% 紧张，产物一律覆盖同一文件，勿新增版本副本 |

## 1. mac 机环境核对

```bash
cd <本地仓库路径> && git pull --ff-only && git log --oneline -1   # 应为 fff2d7d 或更新
ls -la ~/Downloads/_my-aliyun-ecs-2026.pem                        # SSH 密钥（ETERM_SSH_KEY 可覆盖）
flutter --version | head -1                                       # 必须 3.50.x（发布脚本会硬校验）
python3 --version                                                 # 发布脚本生成 JSON/appcast 依赖
```

- flutter 在 `$HOME/development/flutter/bin`（发布脚本已内置该 PATH，手动跑 flutter 需自加）。
- JAVA_HOME 默认钉 JDK17（脚本已带，勿改——GraalVM 的 jlink 过不了 AGP，AGENTS.md 有前科）。

## 2. 任务 A：服务端确认/部署

```bash
KEY=${ETERM_SSH_KEY:-$HOME/Downloads/_my-aliyun-ecs-2026.pem}
ssh -i "$KEY" root@120.26.109.221 'systemctl is-active eterm'    # 应为 active
# 干跑比对：列出生产 /opt/eterm/src 会同步的差异（无输出 = 已是最新）
rsync -rlptD --itemize-changes --dry-run -e "ssh -i $KEY" server/src/ root@120.26.109.221:/opt/eterm/src/ | head
```

- 有差异 → 跑 `server/scripts/deploy.sh`（自带备份/属主/重启/探针）。
- 验证：`curl -s -o /dev/null -w '%{http_code}\n' -X POST https://eterm.etarch.cn/api/v1/auth/password` → **401 = 路由已上线**（404 = 生产还是旧代码；healthz 版本号不能判新旧，别用它）。
- `ssh -i "$KEY" root@120.26.109.221 'journalctl -u eterm --since "5 min ago" | tail -20'` 无异常。

## 3. 任务 B：nginx `/updates/` 上线（⭐ 三端发布的共同解锁项）

```bash
# 1) 勘察线上 conf 实际位置（仓库参考文件是 deploy/nginx-eterm.etarch.cn.conf）
ssh -i "$KEY" root@120.26.109.221 'grep -rl "eterm.etarch.cn" /etc/nginx/ | head'
# 2) 比对仓库 conf 与线上实际文件（路径以上一步为准）
scp -i "$KEY" deploy/nginx-eterm.etarch.cn.conf root@120.26.109.221:/tmp/eterm.conf.new
ssh -i "$KEY" root@120.26.109.221 'diff /etc/nginx/conf.d/eterm.conf /tmp/eterm.conf.new'
#    → 若线上与仓库存在历史漂移：不要直接覆盖，只把 /updates/ location 块手工并入线上 443 server 块
#    → diff 仅差 /updates/ 段 → 覆盖并生效：
ssh -i "$KEY" root@120.26.109.221 'cp /tmp/eterm.conf.new /etc/nginx/conf.d/eterm.conf && nginx -t && systemctl reload nginx'
```

**验证（走客户端真实请求路径）**：

```bash
curl -sI https://eterm.etarch.cn/updates/eterm-android.json | grep -iE 'HTTP|cache-control|strict-transport'
```

- `cache-control: no-cache` **头出现 = /updates/ location 生效**（这是该 location 独有的头；404 状态无所谓——文件还没上传，路由放行即可）。
- 若 404 且无 Cache-Control 头 → 请求仍被 proxy 给中枢，location 没生效，回去查 conf。

## 4. 任务 C：macOS 端（最重，未知数在 Sparkle 首次集成）

### C1. 编译验证 + Podfile.lock 入库

```bash
cd client/app && flutter build macos --debug    # 自动 pod install 拉 Sparkle（Podfile 钉 '~> 2.6'）
```

- 编译失败且指向 XPC/签名/entitlements → 按方案 §8 清单排查（**禁用 `--deep` 签名**、Xcode 调试需关「Debug XPC services」）。
- 通过后：`git add macos/Podfile.lock && git commit`（lock 入库约定，防另一台 mac 版本漂移）。**保持工作区干净**（发布脚本前置校验要求）。

### C2. Sparkle EdDSA 密钥（一次性）

```bash
cd client/app
macos/Pods/Sparkle/bin/generate_keys -x ~/Downloads/eterm-sparkle-ed25519   # 生成并导出私钥文件
chmod 600 ~/Downloads/eterm-sparkle-ed25519
macos/Pods/Sparkle/bin/generate_keys -p   # 或 macos/Pods/Sparkle/bin/sign_update（无参数）打印公钥
```

- 公钥抄进 `macos/Runner/Info.plist` 的 `SUPublicEDKey`（替换 `__ETERM_SPARKLE_EDDSA_PUBLIC_KEY_NOT_SET__` 占位符）→ 重新 `flutter build macos --debug` 让公钥进 bundle → `git add macos/Runner/Info.plist && git commit`。
- **私钥丢失 = 永远无法再给 mac 端发更新**（换钥=换 bundle id 重新首发）。0600 + 异地备份，纳入发布自检。

### C3. 发布（先演练后正式）

```bash
client/app/scripts/release_macos.sh --no-upload   # 演练：bump/构建/zip/appcast 全走，不上传不提交
git checkout pubspec.yaml                          # 演练会 bump 且不提交，先复原
client/app/scripts/release_macos.sh                # 正式：bump → +2，上传后自动 commit+push
```

- 校验项脚本已内置：远端 sha256 一致 + 公网回读 appcast 含 `sparkle:version`（同时验证任务 B 生效）。
- 失败排查：`generate_appcast` 报私钥相关 → `ETERM_SPARKLE_PRIVATE_KEY` 指向确认；curl 回读失败 → 回任务 B。

### C4. mac 端到端（核心用例；mac 是首次分发，注意"先旧后新"）

1. 用**发布前**本地产物（`build/macos/Build/Products/Release/Eterm.app`，bump 前的旧 build）手动放进 `/Applications` 并打开一次；
2. 打开新发布的版本 → Sparkle 提示新版本 → 安装并重启 → 版本号变新；再打开 → 「已是最新」；
3. 降级路径：断网启动 → 静默；设置页手动检查 → Sparkle 报检查失败；
4. 签名路径：篡改 zip 后用错签名生成 appcast → Sparkle 拒装（验证 EdDSA 真在生效）。

## 5. 任务 D：Android 端

1. `cd client/app && flutter build apk --debug` —— **MainActivity.kt 的 Kotlin 首次编译验证**（Windows 机 gradle 分发包损坏，验证留到 mac）。
2. `client/app/scripts/release_android.sh` 正式发布（bump → +3；JSON notes 取 git log 标题；回读校验依赖任务 B）。
3. 真机端到端（关键：**先旧后新**——把发布前的 APK 装到手机再发新版）：
   - 启动 → 「发现新版本」SnackBar → 更新 → 下载进度 → 系统安装确认界面 → 安装完成 → SnackBar 反馈；
   - 权限路径：关掉「允许安装未知应用」→ 引导对话框 → 授权重试 → 装成功；
   - 降级路径：飞行模式启动静默；手动检查 → 「检查更新失败」；
   - 若安装确认界面**不弹出**或一直报「安装失败」→ 回查 MainActivity 的 `FLAG_MUTABLE` / `STATUS_PENDING_USER_ACTION` 处理是否在（评审 P0×2，代码已修，真机是最终裁决）。

## 6. 任务 E：Windows 端（须 Windows 机执行，mac 侧只需完成前置）

- **前提补齐**：pem 密钥不在 Windows 机（11-21 探测）——先从 mac 机把 `~/Downloads/_my-aliyun-ecs-2026.pem` 拷到 Windows 机 `C:\Users\<用户>\Downloads\`（或设 `ETERM_SSH_KEY`），否则 `release_windows.ps1` 的 scp/回读会失败。
- Windows 机：`git pull` → `client\app\scripts\release_windows.ps1`（前置校验/bump/NSIS 打包/上传/回读校验/自动 commit 全已就绪）。
- 端到端（§11.8）：旧 setup（已装的 1.0.0+1）→ 新版发布后应用内「发现新版本」→「退出并安装」→ 应用退出 → 静默安装自动重启 → 版本变新；断网静默；篡改 JSON sha256 → 校验失败拒装删暂存；中文/含空格用户名机器走一遍。

## 7. 任务 F：稳定运行观察

- [ ] `ssh root@120.26.109.221 'df -h /opt'` 磁盘余量（~86% 基线）；
- [ ] 上线初期 `journalctl -u eterm` 无异常；客户端更新检查失败不影响登录/同步/连接（设计已解耦，观察确认）；
- [ ] Windows 机 Defender 首启无拦截；mac Gatekeeper 口径（首次右键打开）传给实际使用者；
- [ ] EdDSA 私钥备份落位（任务 C2）后，在 [eterm-发布流程.md](../eterm-发布流程.md) 核对发布自检清单是否需要勾补。

## 8. 踩坑速查

| 坑 | 说明 |
|---|---|
| healthz 版本号 | 硬编码 `0.1.0-ts`，**不能**用来判断服务端部署新旧；用 401 路由探针 |
| bump 撞号 | 三端共用 pubspec 事实源；脚本已内嵌「clean + pull --ff-only 前置、上传后自动 commit+push」——**人工不要手改 pubspec build 号** |
| `--no-upload` 演练 | 会 bump pubspec 但不提交 → 演练后 `git checkout pubspec.yaml` 复原再正式发布 |
| 覆盖上传约定 | 磁盘紧张：APK/zip/setup.exe/JSON 一律覆盖同一文件名，勿留版本副本 |
| Sparkle Downloader XPC | **不要**启用 `SUEnableDownloaderService`（WebKit 老渲染 + 丧失版本自适应 notes，方案 §7.3） |
| release notes | mac appcast `<description>` 由脚本注入（git log 标题）；Android JSON `notes` 同源；自定义用 `--notes="..."` |

## 9. 文档索引

- [eterm-自动更新方案.md](eterm-自动更新方案.md)（v1.2 设计全集：§4 nginx / §5-§8 三端设计 / §9 发布脚本 / §10 测试 / §11 验收顺序 / §12 风险）
- [eterm-发布流程.md](../eterm-发布流程.md)（三端发布约定 + nginx 分发小节 + 私钥备份）
- [eterm-Windows客户端技术方案.md](eterm-Windows客户端技术方案.md)（§6 Windows 更新设计、§7 发布脚本）
- 评审记录：fff2d7d commit message（P0×2/P1×2/P2×4/P3×10 修复明细）
