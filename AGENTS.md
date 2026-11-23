# AGENTS.md

自托管的主机与凭据数据中枢（eterm）+ 多端客户端。**架构铁律：客户端与目标服务器之间走本地直连（数据面），中枢只承载元数据同步（同步面），中枢永远不出现在数据面上。** 远程：`origin = git@gitee.com:yangjiayi/eterm.git`（main）、`github = git@github.com:DC-ET/eterm.git`（私有镜像，择机开源）。

## 目录

- `server/` — 中枢服务端，**Node 22 + TypeScript + Fastify 5 + mysql2**（⚠️ 根 README 与 Makefile 中的 Go 段落是过时遗留，以本文件为准）
- `client/app/` — Flutter 3.50 客户端（macOS 桌面 + Android + Windows 桌面 + iPhone）；`lib/`（Dart UI/services）+ `rust/`（Rust core：russh 0.46 SSH、rusqlite 本地库、aes-gcm 字段加密，经 flutter_rust_bridge 2.13 frb(sync) 暴露）
- `deploy/` — nginx/systemd/备份样例（自建部署参考；生产实例信息不入库，见本地 private-info.md）
- `docs/` — PRD、技术方案、`eterm-发布流程.md`（改发布相关前必读）

## 常用命令

```bash
# server（在 server/ 下）
npm run typecheck && npm test        # vitest（无需 MySQL 的单测为主）
npm run dev / migrate / create-user  # 需 ETERM_DB_DSN + ETERM_PEPPER + ETERM_MASTER_KEY

# client/app（Flutter）
flutter analyze                      # 必须 0 error 再提交
flutter build macos --debug          # 桌面验证
flutter build ios --simulator --debug # iOS 模拟器构建（cargokit 编 Rust，免签名）
flutter test / cd rust && cargo test --lib   # rust 测试 22 个

# Android 发布（覆盖上传到服务器，勿改约定）
client/app/scripts/release_android.sh        # 产物 sha256 双端校验

# iOS 发布（TestFlight 苹果托管分发，勿改约定；须 ASC API Key）
client/app/scripts/release_ios.sh            # bump → build ipa → TestFlight 上传 → commit bump
client/app/scripts/release_ios.sh --no-upload # 本地演练（--no-codesign 免签名）
```

```powershell
# client/app（Windows，在 Windows 机上）
flutter analyze                     # 门禁同 mac：0 error
flutter build windows --release     # 产物 build\windows\x64\runner\Release\（Eterm.exe）
flutter test                        # 门禁同 mac；cargo test --lib 同左
Push-Location installer; makensis -DVERSION="1.0.0+1" eterm.nsis; Pop-Location  # → build\eterm-windows-setup.exe

# Windows 发布（覆盖上传到服务器，勿改约定；须 Windows 机执行；默认策略被拦时加 -ExecutionPolicy Bypass）
client\app\scripts\release_windows.ps1        # -NoUpload 本地演练；上传校验通过后自动 commit+push bump
```

## 架构与契约（改同步协议前必读）

- **wire 契约只存在于两端隐式约定**：服务端 `syncstore.ts` 的 push 是**部分更新语义**（请求里缺的键不改列；显式 `null` 才清列）。客户端若用 Dart null-aware `?null` 序列化，null 会**省略键** → 静默失败（已踩坑：编辑主机移出分组）。编辑已有实体时必须显式发字段。
- 实体 `data_enc` 服务端静态加密（`ETERM_MASTER_KEY`）；pull 返回**明文**（靠 TLS）。`rev` 在 `data` 内部（非顶层 change-id）；删除走墓碑（`op: delete` + base_rev）。
- Dart 侧实体仓库：`lib/services/app_state.dart`（bootstrap 本地快照 → refresh 增量 cursor 循环 → 折叠进 Rust 本地库）。凭据解析 `credentialFor`：identity.password_enc 或 identity.key_id → ssh_key.private_enc。
- **Rust 只做存储/加密/SSH 数据面**，Dart 驱动 HTTP 同步，不要越层。

## 已知陷阱（都真实踩过）

- **可空语义**：`expr ?? default` 会把"显式 null"替换成默认值（曾致编辑对话框必填死锁）；validator 传"恒通过函数"而非 null。
- **window_manager 0.7 + Flutter 3.50**：旧 API（`windowManager`/`WindowOptions`/`DragToMoveArea`）在 `package:window_manager/legacy.dart`；material_ui 必须 ≥1.11.0（它锁定 window_manager ^0.7）。勿降级。
- **LKMK 主密钥走文件** `data_dir/lkmk.bin`（0600），**不要用 login keychain**（debug ad-hoc 签名变化 → ACL 失配 → SecItemCopyMatching 阻塞 UI 线程 → 黑屏且弹窗藏在 SecurityAgent）。
- **frb sync 函数跑在 UI 线程**：任何可能阻塞（钥匙串、网络）的 Rust 调用必须 async；russh 需要 `static RUNTIME: OnceLock<Runtime>`（`frb::spawn` 无 tokio reactor）。
- **SafeArea 层级**：桌面标题栏 = `Container(深色) > SafeArea > 内容行`（背景延伸到状态栏）；手机（<720 宽）无深色标题栏，浅色 app bar 顶到状态栏下，终端页自带深色状态栏区 + AnnotatedRegion 切图标色。
- 响应式断点：`MediaQuery.width < 720` = 手机布局（底部导航 + 单列列表卡 + FAB），桌面 = 侧栏 + 网格。改终端标签结构时注意：IndexedStack 子树类型随 compact 变化会导致 State 重建 → SSH 断连（已知 P1，结构待改）。
- **SPM 已全局关闭**（`flutter config --no-enable-swift-package-manager`，3.50 默认开但生成器丢插件）；图标经 `flutter_launcher_icons`（`dart run flutter_launcher_icons`）生成，源图在 `client/app/assets/icon/`。
- macOS 自带 bash 3.2：shell 脚本里紧邻非 ASCII 字符的变量必须 `${}` 花括号。
- Android release 必须含 INTERNET 权限（main AndroidManifest）——曾被删导致真机 DNS 失败。
- **任何 `flutter build apk`（含 debug）都要钉 `JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home`**：机器默认 java_home 指向 GraalVM，其 jlink 过不了 AGP 的 JdkImageTransform（assembleDebug 直接失败，报 `core-for-system-modules.jar` transform 错）。release 脚本已钉，手动构建易踩。
- **file_selector 的 `getSaveLocation`/saveFile 在 Android 未实现**（openFile/getDirectoryPath 可用）——下载落盘不能走系统另存为；SFTP 下载写应用专属外部目录（`Android/data/<pkg>/files/sftp-local`，免权限）。SFTP 传输用 `<目标>.eterm-part` 暂存 + 完成后改名，取消/失败保留暂存，重试续传（rust/api/sftp.rs）。
- 服务器磁盘紧张（~86%），APK 按 `docs/eterm-发布流程.md` 约定**覆盖同一文件**，大版本才留副本。

## Windows 端（2026-11-21 接入，方案见 docs/plan/eterm-Windows客户端技术方案.md）

- **Windows 发布必须在 Windows 机上做**（macOS 不能交叉编译）；工具链：Flutter 3.50.x（与 mac 同主版本，脚本前置校验）+ VS 2022「使用 C++ 的桌面开发」+ Rust `stable-x86_64-pc-windows-msvc`（cargokit 必须 msvc，不用 gnu）+ NSIS 3（Unicode）。
- exe 名 `Eterm.exe`（`windows/CMakeLists.txt` 的 `BINARY_NAME`，D13）；`windows/` runner 生成物全部入库，`flutter create --platforms=windows --org dev.eterm .` 生成的 CompanyName 决定数据目录 `%APPDATA%\dev.eterm\eterm\`——**改 runner rc 前先想清楚数据目录迁移**。
- 标题栏三钮在 `lib/ui/shell.dart`（`_WindowControls`）；**双击标题栏最大化沿用 DragToMoveArea 内建**（nativeapi 原生 SC_MAXIMIZE/SC_RESTORE，双端同源）——勿自建手势，原始 Listener 直判会与内建双击同时触发、两次切换互相抵消。
- Windows 机工具链锁定：Flutter **3.50.x**（gitee 镜像 clone，channel 显示 user-branch 属正常；脚本按 3.50 主版本前置校验）+ VS 2022「使用 C++ 的桌面开发」+ Rust `stable-x86_64-pc-windows-msvc`（cargokit 必须 msvc，不用 gnu）+ NSIS 3（Unicode）。
- git 本机 `core.autocrlf input`（防跨平台换行搅动 .sh/.nsis）；`pubspec.lock` 已入库锁定两端插件版本（D14）；ps1/.nsis 含中文，**必须 UTF-8 with BOM**（PowerShell 5.1 无 BOM 按 ANSI 误读）。
- JAVA_HOME 钉 GraalVM 那条不适用 Windows；Windows 机 `flutter build apk` 不受影响（没有该陷阱）。

## iOS 端（2026-11-21 接入，方案见 docs/plan/eterm-iOS客户端技术方案.md）

- **iPhone-only**（`TARGETED_DEVICE_FAMILY=1` + Info.plist 仅 Portrait）：锁竖屏（D15）是硬约束——横屏逻辑宽 ≥720 会翻进桌面布局死分支并触发已知 P1 IndexedStack 重建断连；iPad 兼容模式能跑不承诺（D10）。deployment target = Flutter 3.50 默认 **iOS 15.0**（不主动抬高）。
- 环境（同 mac 主力机）：Flutter 3.50.x + Xcode 26+ + Rust targets `aarch64-apple-ios aarch64-apple-ios-sim` + CocoaPods（SPM 已全局关，正好避开 SPM 生成器坑）；bundle id `dev.eterm.eterm` 与 Android applicationId 同源；真机首连须开「开发者模式」（iOS 16+）。
- 发布须 Apple Developer 付费账号（D2）：**个人账号 ASC 团队只有账号持有者**，内测仅自己可用；给他人装走外部测试组（每 version 首传轻量 Beta 审核）。上传 `xcrun altool` + ASC API Key（altool 被 Xcode 26 移除时兜底 Transporter.app，核验项 #13 定型）；build 号 per-version 单调，bump 不变式与 Android 同构。
- Info.plist：ATS 全放开（D8，内网 `http://` 中枢合法）+ `NSLocalNetworkUsageDescription`（**不声明则内网 SSH 静默失败**）+ `UIFileSharingEnabled`（SFTP 落 `Documents/sftp-local`，「文件」App/Finder 可见）+ `ITSAppUsesNonExemptEncryption=false`（免每次上传的加密合规答题）。
- 后台语义（D4/D13）：iOS 无前台服务等价物，退后台进程挂起、socket 冻结——shell 的 `WidgetsBindingObserver` 回前台触发 `realtime.probe()`（清退避直连）+ 静默对账 + 终端标签自动重连（closed 立即重连 / live 武装 60s 窗口），**仅移动端生效**（桌面 macOS resumed 是窗口聚焦噪声，勿扩闸）。Android 无前台服务挂起时同样受益。
- `file_selector` 的 save 类 API iOS 未实现（与 Android 同病）；`openFile` 返回 security-scoped URL，Rust 直接读的实测结论见方案核验项 #15。
- ios/ 生成物入库边界：Runner 工程/Info.plist/Podfile/**Podfile.lock** 入库（对齐 macos）；`Pods/` 与 `ios/Flutter/` 生成物被根 .gitignore 覆盖（`client/**/Pods/`）。`DEVELOPMENT_TEAM`（个人 Team ID）已入库——换 Apple ID/团队时需改 `ios/Runner.xcodeproj/project.pbxproj`（3 处）。
- flutter_launcher_icons 的 `remove_alpha_ios` 是**根级键**（0.14.4 放 `ios:` 块内被静默忽略，1024 图标带 alpha 上传 ASC 被 ITMS-90717 拒）——本轮 review 实锤。

## 测试账号与环境

> 生产/测试服务器地址、账号密码、密钥路径等敏感信息统一维护在**本地 `private-info.md`**（已 .gitignore，勿提交、勿贴文档）。

- 中枢测试账号：`guitest`——密码与服务器信息见 private-info.md
- 测试主机：k7（root，私钥凭据已入库）；服务器 sshd `PasswordAuthentication no`
- SSH 密钥（发布/运维）：默认 `$HOME/.ssh/your-server.pem`（`ETERM_SSH_KEY` 可覆盖）
