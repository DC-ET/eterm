# eterm · iOS 客户端技术方案

> 版本：v1.1 ｜ 日期：2026-11-21 ｜ 状态：**已评审定稿并实施**（2026-11-21 评审通过；评审补充 P11/D15 已并入；M0/M2 代码改造完成，模拟器全链路验证通过，TestFlight 通路待 D2 账号就绪）
> 上游文档：[eterm-技术方案.md](eterm-技术方案.md)（下称技术方案）。本文只覆盖「新增 iOS 平台目标」这一件事，不重复技术方案已论证的架构铁律。
> 基线口径：**功能范围、交互、视觉以 Android 客户端（手机布局 <720 compact）为准**；不要求 iOS 专属新功能。
> 关联：[eterm-Windows客户端技术方案.md](eterm-Windows客户端技术方案.md)（同构先例，决策编号口径沿用）、[eterm-发布流程.md](../eterm-发布流程.md)（实施本文后需增补 iOS 发布小节）、[eterm-自动更新方案.md](eterm-自动更新方案.md)（iOS **不并入**，见 D5）。
> 一句话结论：**同一 Flutter + Rust 代码库新增 ios 平台目标。手机 UI 与 Rust 数据面近零改动（比 Windows 化还省——手机布局就是现成的 Android 形态，且开发就在现有 mac 主力机上，无跨机成本）；结构性差异集中在三处——分发模型（Apple 开发者账号 + TestFlight，应用内更新禁用）、后台模型（无前台服务，退后台 SSH 会话断开、回前台自动重连）、文件出站模型（沙箱目录 + Files App）。主要成本在苹果生态的外部前提（付费账号、签名、TestFlight 通路），不在代码。**

---

## 1. 背景与现状

### 1.1 需求

照着 Android 客户端的 UI 与功能，提供 iOS 版。功能范围、交互、视觉以 Android 手机形态为准（<720 compact 布局：底部导航 + 单列列表卡 + FAB）；不要求 iOS 专属新功能。

### 1.2 现状盘点：为什么 iOS 代码成本低于 Windows

客户端架构本就是「纯 Rust core + 纯 Flutter 自绘 UI + 少量平台插件」，且**触屏手机形态已被 Android 实现并打磨过**（手势、键条、断点布局、SafeArea 层级都是现成的）。以 Android 为基线的复用矩阵：

| 层 | 资产（位置） | iOS 处置 | 依据 |
|---|---|---|---|
| Rust core 全部 | `client/app/rust/`（ssh/sftp/store/keychain/portfw/util），russh 0.46 + rusqlite(bundled) + aes-gcm | **零改动** | 纯 Rust；`rust_builder/ios/rust_lib_eterm.podspec` 已存在（cargokit 原生支持 iOS），rust_builder/pubspec.yaml 已声明 `ios: ffiPlugin` |
| FFI | flutter_rust_bridge 2.13（钉死） | **零改动** | frb 全平台支持，生成码 `lib/src/rust/` 平台无关 |
| Dart 服务层 | `api_client.dart` / `app_state.dart` / `realtime.dart` / `sftp_transfer_queue.dart` | **近零改动**（realtime 增 `probe()` 探测入口 + 生命周期钩子为增量新增，见 §4.2） | 纯 `dart:io`；`realtime.dart` 已有断线指数退避重连（1s 起步上限 60s），但无主动探测 API——挂起归来后本地连接状态陈旧，D13 补 |
| UI 手机布局 | `shell.dart:164` compact 分支（<720 底部导航 + FAB + 长按菜单） | **零改动** | iPhone 竖屏 390–430 宽天然落在 compact 断点；`main.dart:31` 的 windowManager 桌面闸不含 iOS，自动跳过；横屏由 D15 锁死（P11） |
| 终端组件 | xterm vendor fork（4.0.0-eterm.1）+ `terminal_gestures.dart` | **零改动** | 手势与键条已按触屏设计：`terminal_tab.dart:431` `isTouch = Platform.isAndroid \|\| Platform.isIOS`（iOS 早已被预期），`TerminalPrefs._isTouchDevice` 同样含 iOS（terminal_gestures.dart:235）；长按拖动方向键/双指捏合/键条重排全部直接复用 |
| SFTP 三页 | sftp_page / sftp_entry_page / sftp_edit_page | **一处分支** | `_initLocal` 的 Android 落盘分支（sftp_page.dart:221）旁加 iOS 分支（§4.4）；远端编辑临时文件走 `getTemporaryDirectory()`（sftp_edit_page.dart:62）iOS 天然可用 |
| 前台服务 | `fg_service.dart` + `TerminalForegroundService.kt` | **不适用** | `Platform.isAndroid` 闸，iOS 自动 no-op；iOS 无等价物，语义差异见 §4.2（D4） |
| 应用内更新 | `app_update.dart`（Android PackageInstaller / Windows setup.exe） | **不启用** | `isSupported = Platform.isAndroid \|\| Platform.isWindows`（app_update.dart:135）不含 iOS，天然 no-op（D5：Apple 政策禁止应用内更新） |
| 文件选择 | file_selector ^1.1.0 | **一处注意** | `file_selector_ios 0.5.3+7` 已在 pubspec.lock；`openFile`（上传选文件）可用；`getSaveLocation/saveFile` iOS 未实现（与 Android 同病，AGENTS.md 有案）→ 下载落盘走固定沙箱目录（D6） |
| 数据目录 | path_provider | **零改动** | `path_provider_foundation 2.6.0`（pubspec override）是 Apple 双平台共享实现，iOS 直接解析；落位核验见核验项 #4 |
| 图标 | flutter_launcher_icons ^0.14.4 | **加配置段** | 支持 iOS 生成 AppIcon.appiconset（需 `remove_alpha_ios: true`，带 alpha 的 1024 图标过不了 App Store Connect 校验）；源图 `assets/icon/` 已有 |
| 深浅色/状态栏 | `terminal_tab.dart:262` AnnotatedRegion + SafeArea 层级 | **零改动** | AGENTS.md 手机形态条目已按双移动端设计（终端页深色状态栏区 + 图标色切换） |
| 无平台债 | 无 secure_storage / tray / autostart 类插件 | — | 没有需要「补 iOS 实现」的插件 |

另有一个 Windows 方案里没有的成本优势：**开发、调试、构建、签名全在现有 mac 主力机上**（Xcode 26.4.1 已装、Flutter 3.50.0 已就位，本方案撰写时实测确认），`flutter analyze` / `flutter test` / `cargo test --lib` 门禁同机跑，无 Windows 那样的跨机协同。

### 1.3 三个结构性差异（为什么不能照抄 Windows 的「补平台目录」叙事）

Windows 化的主要工作是环境与打包；iOS 在代码之外有**三条产品级语义差异**，必须在方案层拍板，不是写代码能顺带解决的：

| # | 差异 | Android 现状 | iOS 现实 | 决策 |
|---|---|---|---|---|
| 1 | **分发** | APK 自分发（nginx 覆盖上传） | 苹果不允许自分发；TestFlight 需 **Apple Developer Program 付费账号（$99/年）**，且 build 号同 version 内单调（脚本恒 bump，不受影响） | D2 |
| 2 | **后台** | 前台服务 + 常驻通知保活（M1 三件套） | 无等价物；退后台秒级宽限后进程挂起、socket 冻结，SSH 会话断 | D4 |
| 3 | **更新** | 应用内下载 APK → PackageInstaller 安装 | 应用内更新被 Apple 政策禁止；TestFlight 自带更新提醒 | D5 |

### 1.4 前提问题（开工前必须解决）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1 | **`client/app/ios/` runner 目录不存在** | `client/app/` 有 android/ macos/ windows/，无 ios/ | 需 `flutter create --platforms=ios` 生成 runner（§4.1） |
| P2 | **无 Apple Developer Program 账号** | mac 端走 Sparkle 自分发，全程未与苹果账号体系交互 | TestFlight/真机分发的硬前提（$99/年）；免费个人签名 7 天过期、单机 ≤3 app，只够冒烟不够日常使用 → D2 |
| P3 | **iOS 无前台服务等价物** | Android FgService 保活在 iOS 无对应 | 后台语义降级为「回前台自动重连」（D4 / §4.2） |
| P4 | **应用内更新被平台禁止** | Apple 审核条款禁止应用自更新 | `app_update` 对 iOS 永久 no-op；设置页更新区 iOS 隐藏（D5） |
| P5 | **ATS 默认阻止 http:// 明文** | 登录页允许输入任意自托管中枢地址（含内网 http://，Android 无此限制） | Info.plist 需放宽 ATS（D8），否则 http 中枢用户在 iOS 上无法登录 |
| P6 | **file_selector 的 `getSaveLocation` iOS 未实现** | file_selector_ios 平台实现不含 save 类 API（AGENTS.md 记录了 Android 同病） | SFTP 下载不能走「另存为」，与 Android 同构走固定沙箱目录（D6） |
| P7 | **触屏设置项闸只认 Android** | `settings_page.dart:142`（重排辅助键条）、`:656`（捏合提示）均为 `Platform.isAndroid` | iOS 上这两个触屏功能会错误隐藏，需扩闸（§4.5） |
| P8 | **Rust iOS target 未安装** | 本机 `rustup target list --installed` 实测只有 darwin/android/windows 目标，无 `aarch64-apple-ios` / `aarch64-apple-ios-sim` | cargokit 构建时会自动 `rustup target add`，但环境清单显式列出（§6.1）避免首次构建困惑 |
| P9 | **iOS 边缘右滑返回手势** | 终端/SFTP/远程编辑是 push 进来的全屏页，iOS interactive pop 手势可能误触退出（连接随页面销毁断开） | PopScope 已有三处（shell.dart:256 / sftp_edit_page.dart:220 / settings_page.dart:820）拦 Android 返回键，需验证/补强 iOS 滑动手势路径（D14） |
| P10 | **设备名不分端** | `login_page.dart:54` `deviceName: Platform.isMacOS ? 'eterm-mac' : 'eterm-mobile'`，Android 与 iOS 都落 `eterm-mobile` | 中枢设备管理页无法区分两端（§4.5 改一行） |
| P11 | **双端均未锁屏幕方向，iPhone 横屏宽 ≥720 触发桌面布局死分支** | lib 无 `setPreferredOrientations`，AndroidManifest 亦未锁向；iPhone Pro Max 横屏逻辑宽 932、Pro 852，均 ≥ 720 | 横屏（或旋转瞬间）compact→桌面布局翻转：无窗口系统的破碎 chrome + 已知 P1 IndexedStack State 重建 → 旋转即断连；锁竖屏规避（D15，评审新增） |

---

## 2. 决策记录（待评审）

15 项。备选与不选原因集中在关键项展开，其余一句话即可。

### 2.1 决策总表

| # | 决策点 | 建议方案 | 一句话理由 | 详见 |
|---|---|---|---|---|
| D1 | 总体路线 | **复用现有 Flutter + Rust 代码库，新增 ios 平台目标** | 复用矩阵（§1.2）显示手机形态资产全量复用；独立原生客户端 = 重写整个产品 | §3 |
| D2 | 分发与账号 | **注册 Apple Developer Program（个人，$99/年）+ TestFlight 分发**：自用走内部测试（无需审核），给他人装走外部测试组（每 version 首个 build 需轻量 Beta 审核）；App Store 公开上架一期不做 | 无付费账号则 iOS 版无法交付给任何非开发设备；⚠️ 个人账号不能添加 ASC 团队成员（组织账号专属），内部测试实际只有账号持有者自己——分发给他人必须走外部测试（§2.2，评审修正） | §5 |
| D3 | 设备范围 | **iPhone only（TARGETED_DEVICE_FAMILY=1）**；iPad 不承诺（兼容模式能跑但不验收） | compact 布局按手机竖屏设计；iPad 宽屏会落桌面布局（无窗口概念的死分支） | §2.3 |
| D4 | 后台语义 | **不保活**：退后台 SSH 会话随系统挂起断开，回前台自动重连；本地回滚缓冲保留；不引入任何后台保活 hack | iOS 无合规的长连机制（BGTask/Network Extension 均不合场景）；Termius iOS 同口径；keepalive 15s×3（ssh.rs:96-97）已保证断线快速判死 | §4.2 |
| D5 | 应用内更新 | **iOS 永久不启用**：`isSupported` 不加 iOS；设置页更新区 iOS 隐藏；更新体验由 TestFlight 自带（新 build 自动提醒） | Apple 政策禁止；无任何绕行动机 | §4.8 |
| D6 | SFTP 本地落盘 | **与 Android 同构：固定应用沙箱目录** `Documents/sftp-local`，经 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 让「文件」App / Finder 可见；导出用系统分享面板（share_plus，P2 可选） | getSaveLocation 未实现（P6）；iOS 沙箱内 app 专属目录免权限，语义对应 Android 的 `Android/data/<pkg>/files/sftp-local` | §4.4 |
| D7 | LKMK 本地密钥保护 | **lkmk.bin 方案零改动**（iOS 沙箱 + `#[cfg(unix)]` 0600 天然覆盖）；不引入 iOS Keychain | iOS 沙箱隔离强于 macOS（其他 app 不可读），威胁模型优于现状；macOS 钥匙串 ACL 前科（AGENTS.md/keystore.rs 注释）提示别碰钥匙串 | §4.6 |
| D8 | ATS 策略 | **`NSAllowsArbitraryLoads = true`**（TestFlight 内测期无审核压力）；将来若上架 App Store 再收紧为 exception domains | 登录页允许任意自托管中枢地址（内网 http:// 是合法场景），不能让系统静默挡掉 | §4.3 |
| D9 | 版本号口径 | **pubspec build 号仍为三端唯一事实源**：CFBundleShortVersionString=version、CFBundleVersion=build；TestFlight build 号全局单调递增与 §9.1 跨机 bump 不变式（git pull --ff-only 前置）天然契合 | 与 Android/Windows 同构，发布脚本复用 lib_version.sh | §6.2 |
| D10 | iPad 形态 | **不做专门适配**；iPhone-only 构建在 iPad 上以兼容模式运行，不验收不承诺 | 为 iPad 调桌面布局 = 在无窗口系统的平台上跑窗口 chrome，投入产出不成比例 | §2.3 |
| D11 | 发布脚本 | **`release_ios.sh`（mac 机执行）**：bump → build ipa → 上传 TestFlight → commit+push；**产物不上传自有服务器**（苹果托管分发，磁盘紧张约定不适用） | TestFlight 取代 nginx 分发位；脚本比 Android 版更短 | §6.2 |
| D12 | 功能范围 | **手机布局全功能对齐 Android，iOS 专属新功能为零** | 与 Windows 化（D12）同口径 | §4.7 |
| D13 | 生命周期钩子 | **新增全局 `WidgetsBindingObserver`**：resumed → WS 即时重连探测 + `app.refresh(silent)` + 终端断线重连；paused → 无动作 | iOS 回前台是常态路径（每次切换 app），实时同步与终端重连都挂在这；Android 无前台服务时同样受益 | §4.2 |
| D14 | 返回语义 | **终端/SFTP 全屏页禁用 iOS 边缘右滑 pop**（Android 返回键拦截语义的 iOS 对应物） | 误滑退出 = 断连，比 Android 误触返回键更隐蔽；PopScope 在 iOS 滑动手势路径的行为需实测（核验项 #9） | §4.5 |
| D15 | 屏幕方向 | **iOS 一期锁竖屏**（移动端初始化时 `SystemChrome.setPreferredOrientations([portraitUp])`，仅 `Platform.isIOS` 路径；Android 保持现状不锁） | 双端均未锁向（P11），iPhone Pro Max 横屏逻辑宽 932 ≥ 720 会翻进桌面布局死分支并触发已知 P1 IndexedStack 重建 → 旋转即断连；锁竖屏一行改动零回归，横屏适配并入 P1 结构改造 | §4.5 |

### 2.2 D2 分发与账号（开工硬前提）

| 事项 | 内容 |
|---|---|
| 账号 | Apple Developer Program **个人** 类型（$99/年），App Store Connect 注册审核通常 1–2 个工作日 |
| 分发通道 | **TestFlight 双通道**：内部测试 = ASC 团队成员（**个人账号不能加成员，实际只有账号持有者自己**），无需审核；外部测试 = ≤10,000 人，每 version 首个 build 需轻量 Beta 审核（通常 1 个工作日内过）。**自己用走内测；给他人装（含 GUI 测试者）必须建外部测试组**（评审修正：原表述「内测 ≤100 人」对个人账号不成立，「≤100」是组织账号团队人数上限） |
| 单个 build 有效期 | 90 天，过期需重传新构建 |
| 免费签名兜底 | 无付费账号期间，免费个人签名可真机冒烟（7 天重签、单设备 ≤3 app、不能给他人分发）——只支撑 M0/M1 开发验证，不构成交付能力 |
| App Store 上架 | 一期不做（D2）；技术上无障碍（Termius 在架先例），将来需要再立项：届时需过审（ATS 收紧 D8、更新文案、隐私声明等） |

### 2.3 D3/D10 设备范围

- **iPhone only**：`ios/Runner.xcodeproj` 的 `TARGETED_DEVICE_FAMILY = 1`。iPhone 6.1" 以上机型全支持，最低 iOS 版本以 `flutter create` 生成的默认 deployment target 为准、**不主动抬高**（核验项 #1；Flutter 3.50 生成的默认值待核实，个人工具无理由排除旧设备）。
- **iPad 不承诺**：iPhone-only 包在 iPad 上走系统兼容模式（TestFlight 可装、能跑），出现布局/交互瑕疵不修；iPad 原生适配（768+ 宽落桌面布局 + 去窗口 chrome）留待确有需求再立项。

---

## 3. 总体架构

```
┌────────────────────────────── 同一代码库（client/app）──────────────────────────────┐
│                                                                                      │
│  Dart UI（全量共用；手机 compact 布局为主形态，与 Android 同源）                       │
│    shell(compact) / hosts / 终端(手势+键条) / sftp×3 / keychain / portfw /           │
│    known_hosts / logs / settings                                                     │
│         │ dart:io HTTP + WS（api_client/app_state/realtime）         │               │
│         ▼                                                            ▼               │
│  flutter_rust_bridge 2.13 ──────────────────────────────── 平台插件（均有 iOS 实现） │
│         │                                                  path_provider /           │
│         ▼                                                  file_selector /           │
│  Rust core（零改动，纯 Rust）                                package_info_plus        │
│    SSH 会话 · SFTP · 端口转发 · rusqlite 本地库 ·            （window_manager /        │
│    LKMK+AES-GCM 字段加密 · TOFU                               fg 前台服务不适用 iOS） │
│         │                                                                    │       │
└─────────┼────────────────────────────────────────────────────────────────────┼───────┘
          │                                                                    │
          ▼                                                                    ▼
┌─────────────────────────────┐                          ┌────────────────────────────┐
│ 平台层                      │                          │ 平台层                     │
│ Android：Kotlin 壳          │                          │ iOS：Runner/Xcode          │
│ 前台服务保活 + PackageInstaller│                        │ Info.plist 权限 + 生命周期 │
│ （iOS 不适用，Dart 闸已隔离）│                          │ 自动签名 + TestFlight      │
└─────────────────────────────┘                          └────────────────────────────┘

数据面（不变）：iPhone ──SSH/SFTP 直连──► 目标服务器
同步面（不变）：iPhone ──HTTPS/WSS──► 中枢 hub.example.com（元数据同步）
分发面（新）： mac 构建机 ──IPA──► TestFlight（苹果托管；不经自有服务器）
```

架构铁律照旧：iOS 版的 SSH/SFTP/端口转发全走 Rust 数据面直连目标服务器，中枢只承载元数据同步，**不出现在数据面上**。

---

## 4. 客户端设计

### 4.1 ios/ runner 生成（P1）

```bash
cd client/app
flutter create --platforms=ios --org dev.eterm .
```

- 生成 `ios/`（Runner.xcodeproj、Info.plist、LaunchScreen.storyboard、Podfile）。org **显式传 `--org dev.eterm`**：bundle id 落 `dev.eterm.eterm`，与 Android applicationId（android/app/build.gradle.kts:19 实测确认）完全一致——两端的设备标识、将来的 App ID 注册都走同一口径。
- 生成后核对/设置三处（Xcode 里做一次，产物入库）：
  1. **Display Name = `Eterm`**（Info.plist `CFBundleDisplayName`，create 默认会落 `Eterm`，核对即可）；
  2. **Signing & Capabilities**：勾选「Automatically manage signing」，选 Developer 账号 Team（D2 落实后；M0 阶段可用 Personal Team 先跑模拟器）；
  3. **TARGETED_DEVICE_FAMILY = 1**（D3，默认生成值可能为 "1,2"，需改为 1）。
- `flutter_launcher_icons` 的 pubspec 配置段补：

```yaml
  # ⚠️ remove_alpha_ios 是根级键（0.14.4 只从根级反序列化，放 ios: 块内被静默忽略）
  remove_alpha_ios: true   # 1024 图标带 alpha 过不了 App Store Connect 校验
  ios:
    generate: true
```

- 生成物入库边界（评审明确）：Runner.xcodeproj / Info.plist / Podfile / **Podfile.lock**（对齐 macos 现状，lock 必须入库锁插件版本）入库；`Pods/` 与 `ios/Flutter/` 生成物已被根 .gitignore 覆盖（`client/**/Pods/`、`**/ios/Flutter/.last_build_id`），create 生成后跑一次 `git status` 核对无意外文件即可。mac 端日常 `flutter analyze` / `flutter test` 不受影响（不构建 ios 目标）。
- CocoaPods：Flutter 3.50 iOS 默认走 CocoaPods（SPM 全局已关，AGENTS.md 有案，正好避免 SPM 生成器丢插件坑）；rust_lib_eterm pod 由 rust_builder/ios/rust_lib_eterm.podspec 经 cargokit 自动编 Rust，无需手写桥接。
- **依赖注入提醒**：pubspec 的 `dependency_overrides: path_provider_foundation: 2.6.0` 对 iOS 同样生效（Apple 双平台共享包，2.6.0 有 iOS 实现），无需处理。

### 4.2 后台生命周期与连接语义（P3 → D4/D13，本方案核心差异）

**Android 现状**：有活跃终端标签时启动前台服务（常驻低优先级通知），退后台后进程不被冻结，SSH 数据面长连（不承诺但实际能撑很久）。

**iOS 现实**：没有任何前台服务等价物。时间线是刚性的：

```
退后台 → 约 5s 宽限（系统回收前 UI 无感）→ 可申请 background task 延至 ~30s（不保证）
       → 进程挂起（socket 冻结、时钟停走）→ 任意时长 → 回前台瞬间解冻
```

挂起期间 socket 实际已死。russh keepalive 配置为 15s 间隔 × 3 次失败判死（rust/src/api/ssh.rs:96-97），回前台后最快 ~45s 内判出断线——但等心跳判死体验差，**重连时机应以「回前台」为触发器**（D13）而非心跳超时。

**一期语义（拍板口径）**：

| 环节 | 行为 |
|---|---|
| 有活跃终端标签时退后台 | 不做任何保活动作（无机制可用）；可选增强：原生侧 `beginBackgroundTask` 拉 ~30s 宽限，覆盖「切出去看一眼再回来」的高频场景，**P2 可选项，非一期必做**（需一小段 Swift MethodChannel，约 20 行） |
| 回前台（D13） | 全局 observer 触发：① `realtime` WS 状态探测、断则立即重连（不等退避计时器）；② `app.refresh(silent: true)` 对账；③ 终端标签逐个探测：已断则自动重连并提示（SnackBar「已重连」），本地回滚缓冲保留（Terminal 对象在 Dart 侧未销毁），shell 状态丢失 |
| 长时后台（推送/锁屏过夜等） | 同上，回前台触发；SSH 服务端在挂起期间早已断开（keepalive 15×3 秒级判死），重连即新会话 |
| 服务器侧会话保持 | **不集成**（mosh/tmux 自动化均不做，D4 口径「不承诺后台长连」与 Termius 一致）；建议口径写进 FAQ：需要长任务时用户自行在服务器上跑 `tmux` |

**实现落点**：`shell.dart` 主壳 State 实现 `WidgetsBindingObserver`（`didChangeAppLifecycleState`），或新建轻量 `AppLifecycleHook` 挂到 `_Boot`/`ShellPage`。注意 AGENTS.md frb 陷阱：observer 回调内只做 **async Dart 侧动作**（WS 探测、refresh、走既有 frb async API），不新增 UI 线程 sync Rust 调用。

三个实现前提（评审补充，缺一不可）：

1. **realtime 无主动探测 API**：`realtime.dart` 的 `_ws` 私有且无 ping——挂起归来后本地连接状态是陈旧的（socket 实际已死；解冻瞬间 stream 的 onDone/onError 会先到达并自动走退避重连，但退避计数可能已累积至 60s）。需新增 `probe()` 入口：`_ws` 为空直接重连，否则发一条真实网络动作判活（如静默 refresh 或 WS 文本探测），失败立即 `_connect()` 并清零退避。（实施偏离：probe 最终为**被动判活**——查连接状态 + 清零退避，无主动 WS 帧；主动文本探测有协议风险，refresh 走独立 HTTP 对 WS 死活无信号。清零退避保证解冻后 onDone 到达即 1s 内重连，语义达标；真机核验项 #10 验证。）
2. **终端重连需要触达通道**：会话句柄在各 `TerminalTabViewState` 内部私有（`_sessionId`），shell 层拿不到；tab 内已有完整重连逻辑（`_connect()` 先断旧订阅再重建会话，terminal_tab.dart:142）与断线 UI。需新增轻量注册表（tab 挂载登记、卸载注销），让 observer 能逐 tab 调既有 `_connect()`——**不要在 observer 里重写连接逻辑**。
3. **resumed 防抖**：iOS 上拉通知中心、滑过 App 切换器都产生 inactive→resumed（进程并未挂起），高频触发是常态。仅对「刚从 paused 恢复」或距上次探测 >10s 才执行；防抖后 Android（有前台服务，resumed 时连接通常还活着）路径同样受益。

仓内已有 `WidgetsBindingObserver` 先例（theme.dart:252 `ThemeController`，跟随系统深浅色）——新增 observer 与之并存即可，勿把业务动作塞进 ThemeController。

**与 Android 的关系**：该 observer 对 Android 同样生效（无前台服务时 Android 也会被冻结，observer 补齐这条路径），属「iOS 驱动、双端受益」的改动，不存在 Android 回归风险。

### 4.3 Info.plist 与系统权限（P5）

| Key | 值 | 理由 |
|---|---|---|
| `NSAppTransportSecurity > NSAllowsArbitraryLoads` | `true`（D8） | 登录页允许输入任意自托管中枢地址，内网 `http://` 是合法场景；iOS 默认 ATS 会静默挡明文 HTTP。TestFlight 内测无审核，先用全放开；App Store 上架时收紧为 exception domains + 用途说明 |
| `NSLocalNetworkUsageDescription` | 文案：「连接局域网内的服务器需要本地网络权限」（D8 配套） | SSH 到局域网 IP 会触发 iOS 14+ 本地网络授权弹窗；**不声明此 key 时连接内网地址会静默失败**（无弹窗无报错），必加。用户拒绝授权后内网连接持续失败且表现同普通连接失败——FAQ 提示「设置 > 隐私与安全性 > 本地网络」开启（§7 验收含拒绝路径） |
| `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` | `true`（D6 配套） | 让「文件」App 与 Finder 可见应用 Documents（含 `sftp-local`），替代 Android 的「系统文件管理器可见」 |
| `UIBackgroundModes` | **不声明** | 不申请后台模式（D4），避免无用途的后台声明 |
| `ITSAppUsesNonExemptEncryption` | `false`（评审新增） | SSH/HTTPS 属出口管制豁免的标准加密；不声明则每个 build 都要在 ASC 手工答一次「加密合规」才对测试者可见（重复摩擦），声明后免 |
| `PrivacyInfo.xcprivacy`（隐私清单） | 上架前补；TestFlight 内测期不硬性要求 | required-reason API 声明；归入 §2.2「App Store 上架」将来清单，M3 若 ASC 出警告再提前 |
| `CFBundleDisplayName` | `Eterm` | 品牌 |
| LaunchScreen | `flutter create` 默认 storyboard | 深色启动图微调可后置，非阻塞 |

无其他运行时权限需求：SSH/SFTP/端口转发均走普通 socket；剪贴板、键盘输入无权限；通知不需要（无前台服务通知）。

### 4.4 SFTP 本地侧与文件出站（P6 → D6）

与 Android 完全同构，仅目录语义替换：

| 动作 | Android 现状 | iOS 方案 |
|---|---|---|
| 下载落盘根目录 | `getExternalStorageDirectory()/sftp-local`（系统文件管理器可见、免权限，sftp_page.dart:221） | `getApplicationDocumentsDirectory()/sftp-local`（App 沙箱；经 §4.3 的两个 key 对「文件」App 与 Finder 可见）——`_initLocal` 加 `Platform.isIOS` 分支，`rootFixed = true` 同 Android |
| 上传选文件 | file_selector `openFile`（SAF） | file_selector `openFile`（Files App 选择器），iOS 实现已有（lock 0.5.3+7） |
| 选本机根目录 | 不提供（固定目录） | **不提供**（`getDirectoryPath` 在 iOS 选 security-scoped 目录需 bookmark 机制，复杂度不成比例；一期不做） |
| 「另存为」导出 | 不支持（getSaveLocation 未实现，AGENTS.md 有案） | 同样不支持；**P2 可选增强**：share_plus 拉系统分享面板导出单文件（AirDrop/存储到文件），非一期必做 |
| 传输中断/续传 | `.eterm-part` 暂存 + 完成改名（rust/api/sftp.rs 纯文件逻辑） | **零改动**：iOS 沙箱内 rename 无 Windows sharing violation 类问题 |
| 远端编辑临时文件 | `getTemporaryDirectory()`（sftp_edit_page.dart:62） | 零改动（iOS temp 目录无权限问题） |

### 4.5 触屏 UI 增量改造清单（P7/P10/D14/D15，全部小改）

| 位置 | 改动 | 说明 |
|---|---|---|
| `settings_page.dart:142`（重排辅助键条入口） | `Platform.isAndroid` → `Platform.isAndroid \|\| Platform.isIOS` | 注释已写明这是触屏功能（「桌面隐藏」），iOS 是触屏，闸该扩；封装 `bool get isTouchPhone` 更整洁，二选一 |
| `settings_page.dart:656`（捏合调字号提示行） | 同上 | 同因 |
| `login_page.dart:54`（deviceName） | 三元改为 `'eterm-mac' / 'eterm-ios' / 'eterm-windows' / 'eterm-android'`（Windows 补正——review P1#2：原方案漏列，Windows 会错归 eterm-android） | P10；只影响**新登录**的设备命名，存量 token 名不变（可接受，中枢设备页从此可分端辨识） |
| `shell.dart` / 全屏页 | D14：验证 PopScope 对 iOS interactive pop 的拦截；不够则 iOS 上对终端/SFTP/远程编辑页禁用边缘滑动手势（route 层处理） | 核验项 #10 先实测再定实现 |
| `main.dart` / 移动端初始化 | D15：`Platform.isIOS` 时 `SystemChrome.setPreferredOrientations([portraitUp])` 锁竖屏 | P11：横屏 ≥720 翻桌面布局死分支 + P1 重建断连；Android 不锁、保持现状基线 |
| `main.dart`（其余） | **零改动** | 桌面 windowManager 闸（:31）不含 iOS 自动跳过；`startupSilentUpdateCheck`（:146）内部被 `isSupported` 闸住自动 no-op |
| 终端键条/手势/字号 | **零改动** | `isTouch`/`TerminalPrefs` 已含 iOS（§1.2）；键条渲染在软键盘上方由 viewInsets 驱动，iOS 同机制 |

### 4.6 LKMK 与本地数据（P4 → D7）

- **零代码改动**。iOS 上 `lkmk.bin` / `eterm.db` 落应用沙箱 `Library/Application Support/`（`getApplicationSupportDirectory()`，main.dart:92），具体落位核验项 #4。
- `keystore.rs` 的 0600 收紧是 `#[cfg(unix)]`，iOS 是 unix，天然生效。
- 沙箱数据（lkmk.bin/eterm.db）默认会进 iCloud/iTunes 备份（苹果端加密存储，语义与 Android allowBackup 同级）：一期接受，不做 `NSURLIsExcludedFromBackupKey` 排除硬化；备份反而让换机恢复零成本。
- 威胁模型优于 Windows/macOS 现状：iOS 沙箱保证其他 app 不可读，无需钥匙串。**明确不引入 iOS Keychain**：macOS 端的教训（debug 签名变化 → ACL 失配 → 主线程阻塞黑屏，keystore.rs 头注释有案）在 iOS 生态同样适用，且 lkmk 丢失的代价仅是重新登录 + 首拉 + TOFU 重新确认（本地库可从中枢重建），无永久数据损失——与 Windows 方案 §2.4 同一论证。
- known_hosts TOFU 设备级隔离：iOS 新设备需重新确认指纹，预期行为（与 Windows 同口径）。

### 4.7 功能对齐明细（D12）

| 功能面（Android 基线） | iOS 处置 | 备注 |
|---|---|---|
| compact 壳（底部导航 + FAB + 长按菜单，shell.dart:164+） | 零改动 | iPhone 竖屏天然 <720 |
| 终端（xterm fork + 键条 + 长按拖动方向键 + 双指捏合 + 双击 Tab） | 零改动 | isTouch 闸已含 iOS；**IME 中文输入列验收重点**（核验项 #9） |
| SFTP 三页 | 一处分支（§4.4 落盘目录） | 其余纯 Dart/Rust 逻辑同源 |
| 远程编辑（拉取→改→回传） | 零改动 | temp 目录语义无差异 |
| Keychain（生成/导入 PEM/部署公钥） | 零改动 | 导入走 openFile（iOS 可用） |
| 端口转发（local -L） | 零改动 | iOS 上绑 0.0.0.0 无 Windows 防火墙类弹窗；本地局域网设备访问 iPhone 的转发端口受本地网络权限约束（预期内，验收时观察） |
| Known Hosts / Logs / Settings | 零改动（除 §4.5 两处闸） | 更新区 iOS 隐藏（§4.8） |
| 桌面布局（侧栏 + 网格） | 代码保留，iPhone 不可达 | 宽度 ≥720 才进；iPad 兼容模式可能触发（D10：不承诺不修） |
| Android 前台服务 / 应用内更新 / 返回键拦截 | 平台闸自动隔离 | FgService、app_update 对 iOS no-op |
| 设备管理页显示 | 经 §4.5 deviceName 改动后可分端辨识 | — |

### 4.8 更新入口（P4 → D5）

- `app_update.dart` 的 `isSupported` **不加 iOS**（一行不改）；`startupSilentUpdateCheck` 自动 no-op。
- `settings_page.dart` 「检查更新」入口与自动更新设置区：iOS 上隐藏（该区块当前按 `isSupported` 分支渲染的，核对后若按平台显式分支则补 iOS 排除）。
- 用户侧更新体验由 TestFlight 承担：新 build 上传后 TestFlight 自动推送提醒、一键安装——体验等价于应用内更新，且合规。

---

## 5. 打包签名与分发（D2）

### 5.1 签名体系（Xcode 自动签名，不手管描述文件）

| 场景 | 机制 |
|---|---|
| 模拟器开发调试 | 免签名，`flutter run` 直接跑（M0 主路径） |
| 真机开发调试 | Development 证书 + 自动签名（Xcode 登录 Apple ID；付费账号前用 Personal Team 兜底：7 天过期重签）；iOS 16+ 真机首连需在「设置 > 隐私与安全性 > 开发者模式」开启并重启确认，首次必踩 |
| TestFlight 发布 | `flutter build ipa` → App Store 分发签名 → 上传 App Store Connect |

- App ID（`dev.eterm.eterm`）由 Xcode 自动签名首次构建时自动注册，无手工后台操作。
- `ios/Runner.xcodeproj` 的 Team 设置入库后，异机（仅 mac 机自己）无需重配。

### 5.2 TestFlight 通路

```
release_ios.sh（mac 机）
  bump pubspec build 号
  → flutter build ipa --release（产物 build/ios/ipa/eterm.ipa）
  → 上传 App Store Connect（TestFlight）
  → 上传成功即苹果托管分发，无自有服务器产物/元数据（D11）
  → commit+push bump
```

- **上传工具**：优先 App Store Connect API Key + 命令行上传（`xcrun altool --upload-app --type ios -f <ipa> --apiKey <KEY> --apiIssuer <ISSUER>`，API Key 在 App Store Connect 后台生成、落 `~/.appstoreconnect/private_keys/`）；altool 在新 Xcode 版本中处于弃用通道，**若 Xcode 26 已移除则兜底 Transporter.app（拖拽 .ipa，GUI 一步）**，实测结论回填核验项 #13。
- **build 号单调性**：TestFlight 对同 version 的 build 号要求递增（per-version，跨 version 可复用；脚本恒 bump 不受影响），上传重复号直接拒——`release_ios.sh` 沿用「工作区干净 + git pull --ff-only + bump + 成功后 commit+push」的不变式（与 release_android.sh §9.1 同构，D9），天然满足。
- **处理等待**：上传后 TestFlight 需几分钟~半小时处理：内部测试处理完即对测试者可见（无审核）；外部测试每 version 首个 build 还需轻量 Beta 审核通过才可见（通常 1 个工作日内）。脚本只保证「上传受理成功」，处理/审核完成的查询走 App Store Connect 后台人工确认（一期不做 API 轮询）。
- 测试者侧：装 TestFlight App → 接受邀请链接 → 安装/更新全程苹果托管。

### 5.3 明确不做（分发面）

- App Store 公开上架（D2，一期）；Ad Hoc 分发（100 设备限额 + 手管 UDID，被 TestFlight 取代）；企业签/超级签（合规风险）。

---

## 6. 构建环境与发布脚本（D11）

### 6.1 mac 主力机环境清单（同机开发+构建，无 Windows 式跨机成本）

| 组件 | 版本/说明 | 本机现状（2026-11-21 实测） |
|---|---|---|
| macOS + Xcode | Xcode 26+（含 iOS SDK、模拟器） | ✅ Xcode 26.4.1 (17E202) |
| Flutter SDK | 3.50 stable（与 Windows/Android 发布校验同口径） | ✅ 3.50.0 stable |
| Rust targets | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` | ❌ 待装（P8；cargokit 也会自动补，显式装一次消除首构困惑） |
| CocoaPods | Flutter iOS 依赖管理（SPM 已全局关，正好避开 SPM 生成器坑） | 以 `pod --version` 实测为准（macos 端已在用，预期就绪） |
| Apple Developer 账号 | 付费（D2）；Xcode 登录 + App Store Connect API Key（上传用） | ❌ 待注册（开工硬前提） |
| 真机 | ≥1 台 iPhone（iOS 版本覆盖部署目标） | 用户自备 |

### 6.2 `client/app/scripts/release_ios.sh`（新增，mac 机执行）

```bash
# 0. 前置校验：git status 干净 + git pull --ff-only（§9.1 bump 基于最新 pubspec，同 release_android.sh）；另需 Xcode 已登录 Apple ID 且 ASC 最新协议已接受（未接受新协议是签名/上传的年度经典坑，报错晦涩）
# 1. Flutter 3.50.x 前置校验（同 Android 脚本口径）
# 2. bump pubspec build 号（复用 scripts/lib_version.sh）
# 3. flutter build ipa --release（签名就绪前提；产物 build/ios/ipa/*.ipa）
# 4. 上传 TestFlight（xcrun altool + API Key；Transporter 兜底见 §5.2）
# 5. commit+push（"release: ios $VER+${BUILD}（发布脚本自动 bump）"，与 Android/Windows 同构）
# 无步骤 6：不上传自有服务器、无 JSON 元数据（D5/D11 与 Android 的差异点）
```

- 沿用 AGENTS.md bash 3.2 陷阱纪律：紧邻非 ASCII 字符的变量必须 `${}` 花括号。
- `--no-upload` 本地演练参数（对齐 release_android.sh），供签名/构建冒烟。
- `docs/eterm-发布流程.md` 增补 iOS 发布小节；AGENTS.md 增补 iOS 常用命令与陷阱段。

---

## 7. 测试策略

**门禁不变**（同机跑）：`flutter analyze` 0 error；`flutter test` 全绿；`cd rust && cargo test --lib` 全绿（22 个）。

**模拟器 + 真机手工验收清单**（测试账号 `guitest` 直连生产中枢，目标主机 k7）：

| 域 | 用例 |
|---|---|
| 安装/启动 | 模拟器首装启动 → 真机 TestFlight 安装 → 升级新 build（TestFlight 提醒路径）；冷启/热启 |
| 同步 | 登录 → 首拉 → 主机/凭据/分组增删改 → 与 mac 端互同步（WS 实时 + 离线后增量）；**退后台过夜 → 回前台对账** |
| 终端 | 连接 k7；**中文 IME**（拼音全键盘候选、九宫格、候选上屏、英文/数字切换）；键条全键行为与重排；长按拖动方向键三档速度；双指捏合字号；回滚 2000 行；深浅色切换（终端页状态栏图标色，AnnotatedRegion 路径） |
| 后台语义（D4） | 有活跃终端时退后台 5s/30s/5min/锁屏过夜 → 回前台：连接断开提示 + 自动重连成功；WS 断线重连不闪加载条；无活跃终端时后台往返无副作用 |
| SFTP | 上传（Files App 选文件）/下载（「文件」App 与 Finder 可见 `sftp-local`）；含中文与空格文件名；中断续传（`.eterm-part`）；冲突改名；远端编辑回传；分享面板导出（若一期含 P2 增强） |
| 端口转发 | 绑 127.0.0.1 规则起停；局域网服务经 iPhone 转发访问（本地网络权限弹窗预期） |
| 密钥 | 生成 Ed25519 / 导入 PEM（openFile）/ 部署公钥到 k7 |
| TOFU | 首连确认指纹；known_hosts 设备级隔离（iOS 新设备重新确认，预期）；`eterm-ios` 设备名出现在中枢设备管理页 |
| ATS/网络 | `http://` 内网中枢地址可登录（D8）；`https://` 生产中枢正常；飞行模式 → 离线进入（本地快照渲染）；本地网络权限**拒绝**路径：内网 SSH 失败表现可辨识，去系统设置开启后恢复 |
| 手势/返回 | iOS 边缘右滑在终端页被拦截（D14）；SFTP/远程编辑页返回确认；设置页返回 |
| 安全区 | 刘海/灵动岛机型：终端页深色状态栏区、底部 Home Indicator 不遮键条；横屏已锁（D15）：验证旋转被拒绝且无布局异常（iPad 兼容模式同验） |
| 更新（TestFlight） | 旧 build → 新 build 上传 → TestFlight 提醒 → 更新 → 版本号变新；同 version 同 build 重传被拒（预期，防呆口径） |

---

## 8. 里程碑

| 阶段 | 内容 | 预估 |
|---|---|---|
| M0 | Developer 账号注册（外部依赖，可与其他阶段并行）+ `flutter create --platforms=ios` + 模拟器空壳跑起来（Rust/cargokit 接入 + rust target 安装） | 0.5–1 天 |
| M1 | 全功能零改动假设验证：模拟器 + 真机（Personal Team 签名即可）按 §7 清单过一遍，产出「实际差异清单」 | 1–2 天 |
| M2 | iOS 化改造：SFTP 落盘分支、settings 闸 ×2、deviceName、生命周期钩子（D13：realtime probe + 终端重连注册表 + 防抖）、图标、Info.plist（D6/D8）、锁竖屏（D15）、右滑防护（D14） | 1–2 天 |
| M3 | 签名配置 + release_ios.sh + TestFlight 首传 + 发布流程/AGENTS 文档 | 1–2 天 |

M0–M3 合计约一周（与 Windows 化同级；差异在 M0 依赖账号审批，M3 依赖 TestFlight 通路实测）。

---

## 9. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| **Apple Developer 账号未落实**（分发硬前提，外部依赖） | 高影响/确定发生（若不注册） | D2 列为开工前提，M0 并行注册；未就绪期间 Personal Team 可支撑 M0–M2 开发验证，交付阶段必须有付费账号 |
| **cargokit × Xcode 26 的 iOS 构建兼容性**（本仓 cargokit 在 macos/android/windows 已跑通，iOS 未实测） | 中影响/中概率 | M0 首日即验（模拟器构建）；macos 端同栈已通是信心兜底；问题按 cargokit 社区既有 issue 修 |
| **后台断连与用户预期落差**（Android 前台服务体验迁移落差） | 中 | D4 口径写进 FAQ/设置页说明；回前台自动重连 + 本地回滚缓冲把落差压到最低；tmux 建议口径 |
| xterm fork 的 iOS 未实测路径（IME 候选窗、安全区、硬件键盘） | 中 | vendor fork 有 Android 侧打补丁前科（DEL/宽字符），同路径修；M1 早期真机暴露 |
| ATS 全放开（D8）将来上架时被审 | 低 | 一期不上架；上架时收紧 exception domains 已预留 |
| TestFlight build 号撞号（同 version 同 build 重传） | 低 | §9.1 bump 不变式（pull --ff-only + 成功后 commit）天然防；重传报错即提示，重跑脚本自增 |
| 上传 CLI（altool）在 Xcode 26 被移除 | 低 | Transporter.app 兜底（§5.2）；核验项 #13 实测定型 |
| IndexedStack 重建断连 P1（AGENTS.md 已知）在 iOS 同样存在 | 低（既有债） | 与 Android 完全同构，不新增风险；结构改造另立，不在本文展开 |
| **iPhone 横屏/旋转触发桌面布局死分支 + P1 重建断连**（P11，评审新增） | 中（不规避则大屏机型必现） | D15 锁竖屏一行规避；横屏适配并入已知 P1 结构改造后统一立项 |
| 免费签名 7 天过期导致真机频繁重签 | 低 | 仅 M1 过渡期；付费账号到位后消失 |

---

## 10. 明确不做

- **App Store 公开上架**（D2）——个人工具，TestFlight 内测够用；将来需要再立项。
- **iPad 专属适配**（D3/D10）——iPhone-only 构建；iPad 兼容模式能跑不承诺。
- **应用内更新**（D5）——平台禁止，TestFlight 承担。
- **后台保活的任何 hack**（D4）——不上 BGTaskScheduler 假保活、不上 Network Extension、不集成 mosh；不承诺后台长连（与技术方案 Android 口径一致）。
- **iOS Keychain 存 LKMK**（D7）——lkmk.bin + 沙箱威胁模型已够，钥匙串有 macOS ACL 前科。
- **推送通知**（FCM/APNs 等价物）——无场景（无服务端事件需要推到 iOS）。
- **iPad 分屏 / Mac Catalyst**——无需求。
- **CI 自动构建**——与 Windows 口径一致（手工脚本足够，且签名/上传依赖本机 Xcode 会话）。
- **Share Extension / Files Provider 等扩展**——无场景。

## 11. 开工前核验项（不阻塞评审，M0/M1 逐条出结论写回本文档）

1. ✅ **已回填（2026-11-21）**：Flutter 3.50 默认 deployment target = **iOS 15.0**（不抬高）；`--org dev.eterm` 正确落 bundle id `dev.eterm.eterm`（与 Android applicationId 同源）。生成物入库边界按 §4.1：Runner 工程/Info.plist/Podfile/Podfile.lock 入库，Pods/ 被 `client/**/Pods/` 覆盖；另：create 顺带改写 `.metadata`（ios 平台登记，保留）与 `analysis_options.yaml`（exclude ios/**，保留），并生成模板 `test/widget_test.dart`（引用不存在的 MyApp，必编译失败，**已删除**）。
2. ✅ **已回填（2026-11-21）**：cargokit × Xcode 26.4.1 模拟器构建通过（`flutter build ios --simulator --debug`，240s，风险 R2 排除）；安装到 iOS 26.4 模拟器启动冒烟：RustLib.init → initCore（sqlite+lkmk）→ **登录页渲染正常**，手机 compact 布局与状态栏图标色正确。
3. ✅ **已回填（2026-11-21）**：双 target 已装（aarch64-apple-ios / aarch64-apple-ios-sim）；模拟器 target 构建正常，真机 target 构建与真机安装待 D2 账号就绪（真机签名）。
4. ✅ **已回填（2026-11-21）**：`getApplicationSupportDirectory()` 落 `Library/Application Support/`，`initCore` 自动建目录（eterm.db[-shm/-wal] + lkmk.bin 均就位）；**lkmk.bin 权限 0600**（`#[cfg(unix)]` 在 iOS 生效，D7 验证通过）。
5. ATS：`http://` 明文中枢地址真机登录连通（D8 生效验证）；本地网络弹窗时机与 `NSLocalNetworkUsageDescription` 文案观感（SSH 到内网 IP 触发）。
6. `file_selector_ios`：openFile 在 Files App 选择器的实际交互；确认 `getSaveLocation` 确实抛未实现（预期同 Android）。
7. `UIFileSharingEnabled` 后「文件」App / Finder 对 `Documents/sftp-local` 的可见性与读写。
8. xterm fork iOS IME：拼音候选窗、九宫格、中文/英文混输、硬件键盘（若测）。
9. iOS 边缘右滑手势对终端/SFTP/远程编辑页的实际行为（D14 决定 PopScope 是否够用）。
10. 退后台→回前台时序实测：断线感知延迟、自动重连成功率、本地回滚缓冲保留（D13 验收）。
11. 端口转发在 iOS 的本地访问路径（iPhone 自身 127.0.0.1 + 局域网设备访问）与本地网络权限交互。
12. TestFlight 同 version 同 build 重传的报错表现（发布脚本防呆口径）。
13. Xcode 26 下 `xcrun altool --upload-app --type ios` 是否可用；不可用则 Transporter.app 兜底定型（§5.2）。
14. 深浅色：启动图、登录页、终端页状态栏（AnnotatedRegion）、键条在 iOS 深色模式下的表现。
15. （评审新增）`openFile` 返回路径在 iOS 的读取可行性：文档选择器给的 URL 带 security-scoped 语义（尤其 iCloud Drive / 其他 App 来源的文件），验证 Rust 侧直接读是否可行；不行则 Dart 侧先 `startAccessingSecurityScopedResource` 再传路径。现网调用无参（keychain_page.dart:1107）无类型过滤，PEM 不会被选择器滤掉（无需改）。
16. （评审新增）锁竖屏（D15）后各机型表现 + iPad 兼容模式下的方向锁定行为（iPhone-only 包在 iPad 上默认竖屏窗口）。

> 实施说明（D15 实现路径偏离记录）：锁竖屏采用 **Info.plist 静态声明**（`UISupportedInterfaceOrientations` 仅 Portrait）替代 D15 原文的 Dart `SystemChrome.setPreferredOrientations` 路径——静态声明冷启动即生效、连旋转事件都不产生，且无需 Dart 代码；Dart 侧 `main.dart` 保持零改动（windowManager 闸不含 iOS 自动跳过）。

---

## 附：实施时需改动/新增的文件清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `client/app/ios/*` | 新增 | `flutter create --platforms=ios --org dev.eterm .` 生成后入库；Info.plist（D6/D8 keys）、TARGETED_DEVICE_FAMILY=1、Team 设置 |
| `client/app/lib/ui/shell.dart` | 改 | D13 生命周期 observer（resumed → realtime/refresh/终端重连，含 realtime `probe()` 调用与终端 tab 重连注册表）；D14 右滑防护视核验项 #9 结论 |
| `client/app/lib/services/realtime.dart` | 改（小） | D13①：新增主动探测入口 `probe()`（判活 + 清退避直连；现状 `_ws` 私有无 ping） |
| `client/app/lib/ui/terminal_tab.dart` | 改（小） | D13③：tab 挂载登记/卸载注销的轻量注册表，暴露既有 `_connect()` 供 observer 触达（连接逻辑本身不重写） |
| `client/app/lib/main.dart` | 改（一行） | D15：isiOS 时锁竖屏 `SystemChrome.setPreferredOrientations([portraitUp])`；windowManager 闸 / startupSilentUpdateCheck 均不动 |
| `client/app/lib/ui/sftp_page.dart` | 改 | `_initLocal` 加 iOS 分支（Documents/sftp-local，§4.4） |
| `client/app/lib/ui/settings_page.dart` | 改 | 两处触屏闸扩 iOS（:142/:656）；更新入口区 iOS 隐藏（§4.8） |
| `client/app/lib/ui/login_page.dart` | 改 | deviceName 三元区分 android/ios（:54） |
| `client/app/pubspec.yaml` | 改 | flutter_launcher_icons 加 ios 段（remove_alpha_ios: true） |
| `client/app/assets/icon/` | 不改 | 源图复用 |
| `client/app/rust/`（全部） | **不改** | 含 keystore.rs（D7：iOS unix 路径天然覆盖） |
| `client/app/scripts/release_ios.sh` | 新增 | bump → build ipa → TestFlight 上传 → commit+push（§6.2，复用 lib_version.sh） |
| `docs/eterm-发布流程.md` | 改 | 增补 iOS 发布小节 |
| `AGENTS.md` | 改 | iOS 常用命令与环境锁定口径段 |
| `docs/plan/eterm-自动更新方案.md` | **不改** | iOS 不并入（D5），文档平台范围表述注明即可 |
