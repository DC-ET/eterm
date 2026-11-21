# eterm 发布流程

## Android 安装包

### 约定（2026-11-15 起）

- **上传位置**：服务器 `120.26.109.221:/opt/mao-data/uploads/eterm/`
- **常规更新**：每次**覆盖**同一个文件 `eterm-android.apk`（避免占满服务器磁盘，当前磁盘余量 ~7G）
- **大版本更新**：另存一份带版本号的副本 `eterm-android-vX.Y.Z.apk`（pubspec 的 version 前两段变化时视为大版本，人工判断）
- 产物为 release 签名（debug key，直接可装）；三 ABI 合一（arm64/armv7/x86_64）

### 一条命令发布

```bash
client/app/scripts/release_android.sh                     # 前置校验 + bump + 构建 + 元数据 + 上传 + 校验 + 提交
client/app/scripts/release_android.sh --versioned         # 大版本：额外保留 vX.Y.Z 副本
client/app/scripts/release_android.sh --no-upload         # 本地演练：跳过上传/回读/commit
client/app/scripts/release_android.sh --notes="自定义更新说明"
```

脚本内部：git 干净 + pull --ff-only 前置校验 → pubspec build 号 +1（共用 `lib_version.sh`，§9.1
唯一事实源）→ flutter build apk --release → python3 生成 eterm-android.json（json.dumps 序列化，
notes 取 git log 标题）→ scp 覆盖上传（APK + JSON）→ 远端 sha256 校验 → curl 公网回读 JSON 校验
version/build → **自动 commit+push pubspec bump**（防跨机撞号）。
SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。

### 手动流程（等价）

```bash
cd client/app
flutter build apk --release                       # 产物 build/app/outputs/flutter-apk/app-release.apk
scp -i ~/Downloads/_my-aliyun-ecs-2026.pem \
  build/app/outputs/flutter-apk/app-release.apk \
  root@120.26.109.221:/opt/mao-data/uploads/eterm/eterm-android.apk
```

### 手机安装

apk 传到手机（微信文件传输助手 / 网盘 / USB 拷贝）→ 点开安装（允许"未知来源"）→ 覆盖安装无需卸载旧版。
应用内更新已支持：启动 24h 节流静默检查（发现新版出非模态 SnackBar）+ 设置页「检查更新」手动入口
（下载 → sha256 → PackageInstaller session 安装，自动更新方案 §5/§6）。

### 发布前自检清单

- [ ] `flutter analyze` 无问题、`cargo test --lib`（client/app/rust）全绿
- [ ] 主清单含 `INTERNET` 权限（历史教训：缺它 release 真机 `Failed host lookup`）
- [ ] 登录/同步/连接一轮通过（guitest 测试账号或自有账号）
- [ ] 服务端 `eterm` 服务正常（`systemctl is-active eterm`）

## Windows 安装包

### 约定（2026-11-21 起，D11）

- **上传位置**：同 Android，`120.26.109.221:/opt/mao-data/uploads/eterm/`
- **常规更新**：覆盖同一文件 `eterm-windows-setup.exe`（磁盘紧张约定）；不新增版本副本
- 产物：NSIS per-user 安装器（免 UAC，装 `%LOCALAPPDATA%\Programs\Eterm`）；exe 名 `Eterm.exe`（D13）
- `eterm-windows.json`（自动更新元数据）随包上传；应用内更新（M4）已随自动更新方案落地
  （客户端：下载 setup → sha256 → 退出应用 → `setup /S` 静默安装 → 自动重启，方案 §5.3）
- **必须在 Windows 机上发布**（macOS 不能交叉编译 Windows；环境清单见 Windows 技术方案 §7.1）
- 脚本第 6 步公网回读校验依赖 nginx `/updates/` location 先行生效（见下文「更新分发基础设施」）

### 一条命令发布

```powershell
client\app\scripts\release_windows.ps1            # 前置校验 + bump + 构建 + 打包 + 覆盖上传 + 校验
client\app\scripts\release_windows.ps1 -NoUpload  # 本地演练：跳过上传/回读/提交
```

默认执行策略拦截时：`powershell -ExecutionPolicy Bypass -File client\app\scripts\release_windows.ps1`。

脚本内部：git 干净 + pull --ff-only 前置校验（异机 bump 防 build 号撞号）→ 确保 installer\vc_redist.x64.exe
就位（缺则从 aka.ms 下载，不入库）→ pubspec build 号 +1 → flutter build windows --release →
makensis installer\eterm.nsis（-DVERSION 带 build 号）→ sha256 → scp 覆盖上传（setup + json）→
curl 回读 JSON 校验版本 + ssh sha256sum 双端校验 → **自动 commit+push pubspec bump**
（build 号唯一事实源，防跨机撞号）。
SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。
安装包内含 vc_redist.x64.exe 兜底：目标机缺 VC++ 运行库（MSVCP140/VCRUNTIME140）时安装器
引导 UAC 提权安装，避免首启报缺 dll。

### 手动流程（等价）

```powershell
cd client\app
flutter build windows --release                    # 产物 build\windows\x64\runner\Release\
Push-Location installer; makensis -DVERSION="1.0.0" eterm.nsis; Pop-Location   # → build\eterm-windows-setup.exe
Get-FileHash build\eterm-windows-setup.exe -Algorithm SHA256
scp -i $env:ETERM_SSH_KEY build\eterm-windows-setup.exe root@120.26.109.221:/opt/mao-data/uploads/eterm/eterm-windows-setup.exe
```

### 用户安装/更新

- 手动下载：浏览器会加 MotW，SmartScreen 提示「更多信息 → 仍要运行」（无签名口径，D7）；
  应用内更新链路无 MotW（D8，实施 M4 后）
- 覆盖安装前请退出 Eterm（安装器会检测运行中并拦截）；卸载保留 `%APPDATA%` 用户数据

### 发布前自检清单

- [ ] `flutter analyze` / `flutter test` / `cargo test --lib` 全绿（Windows 机本机跑）
- [ ] 安装 → 启动 → 登录 → 连接 k7 一轮通过
- [ ] 杀软（Defender）首启无拦截；若误报按 Windows 技术方案 §10 缓解

## macOS 安装包

### 约定（2026-11-21 起，自动更新方案 §9.2/§9.3）

- **上传位置**：同 Android/Windows，`120.26.109.221:/opt/mao-data/uploads/eterm/`
- **常规更新**：覆盖同一文件 `eterm-mac.zip` + `eterm-mac.xml`（磁盘紧张约定）
- 产物：zip 内含 `Eterm.app`（ditto 打包）+ Sparkle appcast（EdDSA 签名）；应用本身保持 ad-hoc 签名，首次安装需右键打开（Gatekeeper）
- 应用内更新走 Sparkle 2 标准界面（启动自动检查 + 设置页手动入口）；沙盒 + Installer XPC 集成见方案 §7/§8
- **必须在 mac 机上发布**（同 Android）

### 一条命令发布

```bash
client/app/scripts/release_macos.sh              # 前置校验 + bump + 构建 + appcast + 上传 + 校验 + 提交
client/app/scripts/release_macos.sh --no-upload  # 本地演练
client/app/scripts/release_macos.sh --notes="自定义更新说明"
```

脚本内部：git 干净 + pull --ff-only 前置校验 → **前置拦截 Info.plist 里 SUPublicEDKey 占位符** →
pubspec build 号 +1（共用 `lib_version.sh`）→ flutter build macos --release → ditto zip →
Sparkle `generate_appcast`（`--ed-key-file` 私钥走文件，暂存目录只放新 zip 不生成 delta）→
python3 注入 `<description>` → scp 覆盖上传 → 远端 sha256 校验 + curl 回读 appcast 校验
sparkle:version → 自动 commit+push pubspec bump。
SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。

### EdDSA 私钥管理（一次性，§9.3）

```bash
macos/Pods/Sparkle/bin/generate_keys                                        # ① 先生成（存入钥匙串，无参）
macos/Pods/Sparkle/bin/generate_keys -x ~/Downloads/eterm-sparkle-ed25519   # ② 再导出私钥文件（-x 只导出不生成，0600）
macos/Pods/Sparkle/bin/generate_keys -p                                     # 打印公钥
# 把公钥写进 macos/Runner/Info.plist 的 SUPublicEDKey（脚本前置校验拦截占位符）
```

**私钥丢失 = 永远无法再给该 app 发更新**（换钥 = 换 bundle id 重新首发）。私钥文件纳入异地备份；
每次 mac 发布前确认文件存在（脚本已校验）。

### 发布前自检清单

- [ ] `flutter analyze` / `flutter test` 全绿（mac 机本机跑）
- [ ] `Eterm.app` 放 `/Applications` → 旧包升新包端到端（方案 §11.5：提示新版本 → 安装并重启 → 版本变新）

## 更新分发基础设施（nginx `/updates/`，三端共用）

- `deploy/nginx-eterm.etarch.cn.conf` 的 443 server 块把 `/updates/` alias 到
  `/opt/mao-data/uploads/eterm/`（无鉴权静态分发；location 内重复声明了三条安全响应头——
  nginx 的 add_header 不继承规则，见自动更新方案 §4）
- 该 location 是三个发布脚本公网回读校验的**运行前置**：未生效时
  `release_windows.ps1`/`release_android.sh`/`release_macos.sh` 的回读步骤都会失败
- 线上生效：改服务器 `/etc/nginx/` 下对应 conf → `nginx -t` → `systemctl reload nginx` →
  `curl -I https://eterm.etarch.cn/updates/eterm-android.json` 验证（404 也算通：路由已放行，只是文件未上传）

## 服务端部署（Node/TS）

### 生产形态

- systemd 单元 `/etc/systemd/system/eterm.service`：以用户 `eterm` 跑
  `/usr/local/eterm-node/bin/node node_modules/tsx/dist/cli.mjs src/main.ts serve`，
  工作目录 `/opt/eterm`，环境文件 `/etc/eterm.env`（0600）
- **`/opt/eterm` 不是 git 仓库**，源码靠 rsync 同步；`node_modules` 已在服务器上
- `/usr/local/bin/eterm` 是 Go 时代遗留静态二进制，**不在服务链路上**（别被它迷惑）
- `serve` 启动时会自动跑迁移（`main.ts` 调 `runMigrations`），并把 goose 时代的
  `goose_db_version` 收编为基线，不会重放 DDL；监听端口以 `/etc/eterm.env` 的
  `ETERM_LISTEN` 为准（生产 8220，前面挡 nginx）

### 发布前自检（server/ 下）

- [ ] `npm run typecheck`
- [ ] `npm test` —— **必须配本地 MySQL**：
      `ETERM_TEST_DSN='root@tcp(127.0.0.1:3306)/mysql?parseTime=true' npm test`（27 个）
      不设 DSN 时 api/sync/code-review 三个套件会报 `ETERM_TEST_DSN 未设置`而失败，
      那是环境未配，不是代码回归

### 一条命令部署

```bash
server/scripts/deploy.sh            # 备份 → rsync src+migrations → 改属主 → 重启 → 探针验证
```

脚本内部等价于：

```bash
# 1. 备份（回滚用）
ssh root@120.26.109.221 'tar czf /opt/eterm-src-backup-$(date +%Y%m%d).tgz -C /opt/eterm src migrations'
# 2. 同步源码（package.json/lock 有变更时才需要在服务器 npm ci）
rsync -rlptD --delete -e "ssh -i $ETERM_SSH_KEY" server/src/       root@120.26.109.221:/opt/eterm/src/
rsync -rlptD --delete -e "ssh -i $ETERM_SSH_KEY" server/migrations/ root@120.26.109.221:/opt/eterm/migrations/
# 3. 属主（服务用户）+ 重启
ssh root@120.26.109.221 'chown -R eterm:eterm /opt/eterm/src /opt/eterm/migrations && systemctl restart eterm'
```

SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。

### 部署后验证

- [ ] `systemctl is-active eterm` → `active`
- [ ] `curl https://eterm.etarch.cn/healthz` → `{"status":"ok","version":"0.1.0-ts"}`
      （版本号是源码硬编码，**不能用来判断新旧**）
- [ ] 新路由探针：`curl -o /dev/null -w '%{http_code}' -X POST https://eterm.etarch.cn/api/v1/auth/password`
      → **401 = 路由已上线**；404 = 部署的还是旧代码
- [ ] `journalctl -u eterm --since "3 min ago"` 无异常（迁移/数据库就绪/listen）

### 回滚

```bash
ssh root@120.26.109.221 'cd /opt/eterm && tar xzf /opt/eterm-src-backup-<日期>.tgz \
  && chown -R eterm:eterm src migrations && systemctl restart eterm'
```

### 历史教训

- 2026-11-20：生产 `/opt/eterm/src` 停留在 TS 重写当天（11-14），之后三个 commit
  （P0 跨 vault 安全修复、Snippets 下线、修改密码）均未部署，客户端改密码 404。
  **每次服务端 commit 后都要跑部署**，不要等客户端报障才发现。
