# eterm · Windows 客户端技术方案

> 版本：v1.1 ｜ 日期：2026-11-21 ｜ 状态：**已拍板，未实施**（当日评审定稿：D2/D4/D7/D9·D10 现场确认，其余按建议通过）
> **v1.1 变更**：可行性复审补充 9 处（不改已拍板决策）：§4.1 create 命令显式 `--org dev.eterm` + BINARY_NAME/exe 名口径；§5 与核验项 #7 VC++ 运行库；§6 下载落盘目录与传输中断语义；§7.1 autocrlf；§7.2 bump 前置校验（修正「无竞态」表述）+ 执行策略；§8 中文用户名用例；§10 pubspec.lock 漂移风险；核验项 #8 旧 Win10 根证书；修正 §4.1 核验项编号引用（#7→#6）。同场拍板两项新决策：**D13** exe 名统一 `Eterm`、**D14** pubspec.lock 入库锁定。
> **v1.0 变更**：D2 定稿为「在手头 x64 Windows 机上直接开发与构建」（用户确认可在 Windows 上开发），VM/云机降为兜底；随之取消「ARM64 VM 产 x64」核验项。
> 上游文档：[eterm-技术方案.md](eterm-技术方案.md)（下称技术方案）。本文只覆盖「新增 Windows 平台目标」这一件事，不重复技术方案已论证的架构铁律。
> 关联：[eterm-自动更新方案.md](eterm-自动更新方案.md)（Windows 更新机制并入其分发体系，见 §6）、[eterm-发布流程.md](../eterm-发布流程.md)（实施本文后需增补 Windows 发布小节）。
> 一句话结论：**同一 Flutter + Rust 代码库新增 windows 平台目标。Rust 数据面与全部业务 UI 零改动/近零改动，改造集中在窗口 chrome（自绘标题栏补窗口控制钮）、打包发布（NSIS + PowerShell 脚本）与构建环境（在 Windows 机上一次性搭好工具链）三处。**

---

## 1. 背景与现状

### 1.1 需求

照着 Mac 客户端（Flutter 3.50 桌面布局）的 UI 与功能，提供 Windows 版客户端。功能范围、视觉、交互以 macOS 桌面形态为准；不要求 Windows 专属新功能。

### 1.2 现状盘点：为什么 Windows 成本低

客户端架构本就是「纯 Rust core + 纯 Flutter 自绘 UI + 平台插件只有少量、且均有 windows 实现」，Windows 化接近"补一个平台目录"：

| 层 | 资产（位置） | Windows 处置 | 依据 |
|---|---|---|---|
| Rust core 全部 | `client/app/rust/`（ssh/sftp/store/keychain/portfw/util），russh 0.46 + rusqlite(bundled) + aes-gcm | **零改动** | 纯 Rust；`rust_builder/windows/CMakeLists.txt`（cargokit 胶水）已存在 |
| FFI | flutter_rust_bridge 2.13（钉死） | **零改动** | frb 全平台支持，生成码 `lib/src/rust/` 平台无关 |
| Dart 服务层 | `api_client.dart` / `app_state.dart` / `realtime.dart` / `sftp_transfer_queue.dart` | **零改动** | 纯 `dart:io`，无平台分支 |
| UI 全部页面 | shell/hosts/sftp×3/keychain/portfw/known_hosts/logs/settings | **零改动**（仅标题栏例外，见 §4.2） | Flutter 自绘，无原生控件依赖 |
| 终端组件 | xterm vendor fork（`client/third_party/xterm`，4.0.0-eterm.1，Canvas 自绘） | **零改动** | 纯 Dart；字体已按平台分支，Windows 已是 `Consolas`（terminal_tab.dart:46-50） |
| 文件选择 | file_selector ^1.1.0 | **零改动** | `file_selector_windows` 0.9.3+6 已在 pubspec.lock，`openFile`/`getDirectoryPath` 全可用 |
| 数据目录 | path_provider | **零改动** | `path_provider_windows` 2.3.0 已在 lock；`pubspec.yaml` 的 `path_provider_foundation` override 是 Apple 平台专用包，不影响 Windows 解析 |
| 窗口管理 | window_manager ^0.7.0（legacy API） | **初始化零改动，标题栏需改造** | `lib/main.dart:28` 桌面分支已含 `Platform.isWindows`；但 `_TitleBar` 无 Windows 窗口控制钮（P3） |
| 应用信息 | package_info_plus ^10.2.2 | **零改动** | 有 windows 实现 |
| 图标 | flutter_launcher_icons ^0.14.4 | **加配置段** | 支持 windows 生成 ico 并写入 runner.rc；源图 `assets/icon/` 已有 |
| 无平台债 | 无 flutter_secure_storage / tray / autostart / updater 插件 | — | 没有需要"补 windows 实现"的插件 |

另有两个"负成本"要点：

- **响应式手机布局（<720 底部导航）在 Windows 上不可达**（窗口最小 960×640，main.dart:33），代码保留即可，天然规避 AGENTS.md 记录的 IndexedStack 重建断连 P1。
- **本地库与同步链路完全平台无关**：data_dir 由 `getApplicationSupportDirectory()` 决定（main.dart:87），Windows 上落 `%APPDATA%\…`（具体值见核验项 #1）；`eterm.db`、`lkmk.bin`、kv、游标、TOFU 全部照搬，无一行平台代码。

### 1.3 前提问题（开工前必须解决）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1 | **`client/app/windows/` runner 目录不存在** | `client/app/` 仅 `android/`、`macos/` | 需 `flutter create --platforms=windows` 生成 runner（§4.1），并准备 MSVC/Rust 工具链 |
| P2 | **macOS 无法交叉编译 Windows 包，且无任何 Windows 构建资产** | Flutter 官方不支持从 macOS 产 Windows 桌面包；仓库无 CI（无 `.github/`）、scripts/ 仅 release_android.sh | Windows 端开发/构建须在 Windows 机上进行（D2：用户手头 x64 Windows 机直接开发） |
| P3 | **自绘标题栏没有 Windows 窗口控制钮** | `lib/ui/shell.dart:444-501` `_TitleBar`：52px 深色 Container > SafeArea > DragToMoveArea，左侧 78px 交通灯让位区，右侧无 min/max/close；`TitleBarStyle.hidden` 在 Windows 会隐藏整条标题栏且无系统按钮 | 没有它窗口无法最小化/关闭，属 P0 功能缺口（D4 / §4.2） |
| P4 | **lkmk.bin 的 0600 收紧是 unix-only** | `rust/src/util/keystore.rs:13-26` `#[cfg(unix)]` 才 chmod | Windows 上文件权限语义不同，需决策保护策略（D5） |
| P5 | **发布脚本与流程无 Windows 位** | `client/app/scripts/` 仅 `release_android.sh`；`docs/eterm-发布流程.md` 无 Windows 小节 | 新增 PowerShell 发布脚本 + 流程文档增补（D11 / §7） |
| P6 | **自动更新方案未覆盖 Windows** | [eterm-自动更新方案.md](eterm-自动更新方案.md) §2.1 平台范围为 Android + macOS | Windows 更新机制并入该体系（D8 / §6） |
| P7 | **端口转发监听地址是规则可配的，非 loopback 绑定会触发 Windows 防火墙弹窗** | `rust/src/api/portfw.rs:101-111` `pf_listen(bind_addr, …)` 直接 `TcpListener::bind((bind_addr, local_port))` | 产品行为需文档化：绑 127.0.0.1 不弹防火墙；绑 0.0.0.0 首次会弹授权（§8 验收清单覆盖） |

---

## 2. 决策记录（待评审）

14 项已拍板（D1–D12 于 2026-11-21 评审定稿：D2/D4/D7/D9·D10 现场确认，其余按建议通过；D13/D14 为同日可行性复审补充拍板）。备选与不选原因集中在关键项展开，其余一句话即可。

### 2.1 决策总表

| # | 决策点 | 拍板结果 | 一句话理由 | 详见 |
|---|---|---|---|---|
| D1 | 总体路线 | **复用现有 Flutter + Rust 代码库，新增 windows 平台目标** | 复用矩阵显示 90%+ 资产零改动；独立原生客户端 = 重写整个产品 | §3 |
| D2 | 构建环境 | **在手头 x64 Windows 10+ 物理机上直接开发与构建**（用户确认可在 Windows 上开发）；VM/云机仅作兜底；不引入 CI | macOS 无法交叉编译（P2）；用户有 Windows 开发机后，外部依赖消解为一次性环境搭建 | §2.2 |
| D3 | 目标架构与系统 | **仅 Windows 10 及以上、x64**；ARM64 暂不发布 | 主流用户 x64；Windows on ARM 自带 x64 仿真，ARM 设备也能用 x64 包 | §2.3 |
| D4 | 窗口标题栏 | **沿用 `TitleBarStyle.hidden` 自绘 + 右侧自绘 min/max/close 三钮**；放弃 Win11 snap-layouts 悬停面板；不做 WM_NCHITTEST 原生命中 | 与 macOS 视觉/代码一致，改动最小；键盘 Win+方向键 snap 仍由系统接管 | §4.2 |
| D5 | LKMK 本地密钥保护 | **一期不做 Windows 额外加固**（维持纯文件 `%APPDATA%…/lkmk.bin`），预留 DPAPI 升级路径；不引入 Credential Manager / flutter_secure_storage | `%APPDATA%` 用户 profile 默认 ACL 已隔离其他标准用户，威胁模型与 macOS 现状相当 | §2.4 |
| D6 | 安装包形态 | **NSIS 3（Unicode）per-user 安装器**（免 UAC，装 `%LOCALAPPDATA%\Programs\Eterm`），手写 .nsis；不做 MSIX / 便携 zip | 静默升级（/S）必须走安装器——运行中的 exe 在 Windows 被锁定，zip 便携形态无法自更新 | §2.5 |
| D7 | 代码签名 | **一期不做**（与 macOS ad-hoc 口径一致，接受 SmartScreen「更多信息→仍要运行」）；应用内更新下载绕过 MotW；预留证书升级 | 个人工具 + debug 口径的分发现状；证书成本与年费不值一期投入 | §2.6 |
| D8 | 自动更新 | **并入既有自动更新方案三端体系**：`eterm-windows.json` + 应用内下载 setup → sha256 → 退出应用 + spawn `setup.exe /S` → 安装器末段自动重启 | 与 Android 同构复用 nginx `/updates/`；Windows 上只有"安装步骤"不同 | §6 |
| D9 | 托盘 / 最小化到托盘 / 开机自启 | **不做** | macOS 现状即关窗即退出、无托盘；Windows 保持行为一致，避免新增平台语义 | §11 |
| D10 | 单实例锁（防双开） | **不做** | 与 macOS 一致；SQLite WAL + 中枢同步对双开有基本容忍 | §11 |
| D11 | 发布脚本与磁盘约定 | **`release_windows.ps1`（Windows 侧执行）**，内嵌 bump_build 语义；产物**覆盖同一文件** `eterm-windows-setup.exe`（沿磁盘紧张约定） | 与 release_android.sh 同构；异机执行无文件竞态，但 bump 必须基于最新 pubspec（§7.2 前置校验） | §7 |
| D12 | 功能范围 | **桌面布局全功能对齐 macOS，Windows 专属新功能为零** | 复用矩阵决定的功能面天然全量；差异仅在标题栏与打包 | §4.5 |
| D13 | Windows exe 名 | **`BINARY_NAME` 统一为 `Eterm`**（产物 `Eterm.exe`） | 与 macOS PRODUCT_NAME=Eterm 品牌口径一致；Runner.rc 的 ProductName 不随之变，数据目录稳定 | §4.1 |
| D14 | Dart 依赖锁定 | **pubspec.lock 入库**（.gitignore 已移除忽略行，下次任一端 `pub get` 生成后提交首份 lock） | 与 Cargo.lock 对称锁两端插件版本；Flutter 应用官方推荐提交 lock | §10 |

### 2.2 D2 构建环境（已定稿：Windows 机直接开发）

用户确认可在 Windows 上开发 → **开发、调试、发布构建同机完成**，原「macOS 交叉编译不可行」的外部依赖消解为一次性环境搭建（清单见 §7.1）：

| 用途 | 方案 |
|---|---|
| 日常开发 / 热重载 / 手工验收 | 手头 x64 Windows 10+ 物理机（Flutter + VS 2022 + Rust + NSIS 装在本机） |
| x64 发布构建 | 同一台机器执行 `release_windows.ps1`（§7.2） |
| 双端协同 | 与 mac 端并行开发经 git（gitee 远程）；`flutter create --platforms=windows` 生成物入库，mac 端 analyze/test 不受影响 |
| 兜底 | 阿里云按量付费 Windows Server ECS（主力机不可用时临时开 1–2 小时）；GitHub Actions 已否决（gitee 远程需镜像维护，个人项目不值） |

### 2.3 D3 目标架构与系统要求

- **x64 only**：Flutter Windows 桌面最低系统为 Windows 10；Win7/8 明确不做。
- Windows on ARM 设备经仿真运行 x64 包可用（性能略降，可接受）；若将来实测 VM 能产 arm64 包且确有需求再发布，本期不做。
- 安装器与应用版本信息（exe VERSIONINFO）统一按 x64 标注。

### 2.4 D5 LKMK 在 Windows 上的保护语义

- 现状：`keystore.rs` 的 0600 是 `#[cfg(unix)]`，Windows 不做任何权限收紧——文件落 `%APPDATA%\<…>\lkmk.bin`，继承用户 profile 默认 ACL（同机**其他标准用户**默认不可读；管理员/物理接触者可读）。
- 该威胁模型与 macOS 现状相当（登录钥匙串方案当年也是被 ACL 问题劝退的，AGENTS.md 有案）。**一期接受默认 ACL**。
- 若将来要加固，升级路径（不在本期）：Rust 侧 `#[cfg(windows)]` 用 DPAPI（`CryptProtectData`）包一层 lkmk 内容，约 20 行平台分支；**不引入** flutter_secure_storage（新插件面 + 与"主密钥走文件"的既有决策冲突）。
- 后果说明（为什么敢接受）：本地库是**可从中枢重建的缓存**——lkmk 丢失/目录变更的代价只是重新登录 + 首拉 + TOFU 重新确认，无永久数据损失。

### 2.5 D6 NSIS per-user 安装器

- **per-user 免 UAC**（`RequestExecutionLevel user`，类似 VS Code 默认安装位），装 `%LOCALAPPDATA%\Programs\Eterm`；开始菜单快捷方式 + 可选桌面快捷方式；卸载项注册在 HKCU。
- **升级 = 覆盖安装**；NSIS 写文件遇运行中的 Eterm.exe 会失败 → 自动更新流程强制「先退出再安装」（D8/§6）；手动覆盖安装时安装页提示先关闭应用。
- 静默参数 `/S`（安装与卸载均支持）；NSIS 3 Unicode 构建（中文文案）。
- **卸载保留用户数据**（`%APPDATA%` 下 eterm.db/lkmk.bin 不删），与 macOS「删 .app 不删数据」语义一致；卸载器内提供可选「删除数据」复选框可选实现（一期可不提供）。
- 否决备选：**MSIX**（签名与 side-load 复杂，更新机制绑 AppInstaller，与既有 nginx/JSON 体系不合）；**便携 zip**（运行中 exe 无法自我替换，自动更新做不了）。

### 2.6 D7 代码签名与 SmartScreen

- 一期不签名，口径与 macOS 一致（ad-hoc + Gatekeeper 右键打开）。
- **关键利好**：应用内更新用 `dart:io` 落盘，**不产生 Mark-of-the-Web**（Zone.Identifier 由浏览器等保存方写入，原始 socket 写文件不写）→ 应用内更新链路运行 setup.exe 不会叠加额外 SmartScreen 拦截；只有用户**经浏览器**手动下载安装包时才吃 MotW + SmartScreen 提示（可接受，口径写进发布文档）。
- 无签名 exe 的杀软误报风险见 §10；预留升级路径：将来需要时买 OV/EV 证书接入 NSIS 签名，架构不变。

---

## 3. 总体架构

```
┌────────────────────────────── 同一代码库（client/app）──────────────────────────────┐
│                                                                                      │
│  Dart UI（全量共用，仅标题栏平台分支）                                                │
│    shell / hosts / sftp×3 / keychain / portfw / known_hosts / logs / settings        │
│         │ dart:io HTTP + WS（api_client/app_state/realtime）        │                │
│         ▼                                                           ▼                │
│  flutter_rust_bridge 2.13  ────────────────────────────────────  平台插件           │
│         │                                                  file_selector /           │
│         ▼                                                  path_provider /           │
│  Rust core（零改动，纯 Rust）                                window_manager /         │
│    ssh 会话 · SFTP · 端口转发 · rusqlite 本地库 ·           package_info_plus        │
│    LKMK+AES-GCM 字段加密 · TOFU                                （均有 windows 实现）  │
│         │                                                                  │        │
└─────────┼────────────────────────────────────────────────────────────────┼────────┘
          │                                                                │
          ▼                                                                ▼
┌─────────────────────┐                                    ┌──────────────────────────┐
│ 平台层              │                                    │ 平台层                   │
│ macOS：Runner/Swift │                                    │ Windows：runner/CMake    │
│ 交通灯让位标题栏    │                                    │ + 自绘 min/max/close 钮  │
│ CocoaPods/SPM-off   │                                    │ MSVC + cargo(cargokit)   │
└─────────────────────┘                                    └──────────────────────────┘

数据面（不变）：客户端 ──SSH/SFTP 直连──► 目标服务器
同步面（不变）：客户端 ──HTTPS──► 中枢 hub.example.com（元数据同步 + /updates/ 静态分发）
```

架构铁律照旧：Windows 版的 SSH/SFTP/端口转发全走 Rust 数据面直连目标服务器，中枢只承载同步与更新元数据分发，**不出现在数据面上**。

---

## 4. 客户端设计

### 4.1 windows/ runner 生成（P1）

```bash
cd client/app
flutter create --platforms=windows --org dev.eterm .
```

- 生成 `windows/`（CMakeLists、runner C++/rc、runner.exe.manifest）。org **显式传 `--org dev.eterm`**（与 android/macos 一致）：org 写入 Runner.rc 的 CompanyName，直接决定 path_provider_windows 的 `%APPDATA%\<CompanyName>\<ProductName>` 落位（§4.4），不要依赖 create 对既有平台的隐式推断行为；创建后核对 `windows/runner/Runner.rc` 的 CompanyName/ProductName（核验项 #6 与 #1）。
- **exe 名已拍板（D13）**：生成后把 `windows/CMakeLists.txt` 的 `BINARY_NAME` 统一改 `set(BINARY_NAME "Eterm")`（默认为 `eterm`），与 macOS 品牌口径（bd189bd 的 PRODUCT_NAME=Eterm）一致，§5/§6 的 exe 引用随之对齐；Runner.rc 的 ProductName 不随之变，数据目录保持稳定，勿为改名重生成 runner。
- `flutter_launcher_icons` 的 pubspec 配置段补 `windows: generate: true`（生成 ico 并更新 runner.rc），源图复用 `assets/icon/`。
- 生成物全部入库（在 Windows 开发机上执行，D2）；此后 mac 端日常 `flutter analyze` / `flutter test` 不受影响（不构建 windows 目标）。
- flutter 的 Windows manifest 默认 Per-Monitor V2 DPI aware，高分屏开箱即用，无需处理。

### 4.2 标题栏与窗口控制（P3 → D4）

**现状**（`lib/ui/shell.dart:444-501`）：`_TitleBar` = 52px 深色 Container > SafeArea > DragToMoveArea；左 78px 交通灯让位区（macOS 专用）；右侧只有 Vaults 胶囊与终端标签 pills。

**改造**：`_TitleBar` 内按平台分支布局——

- **左侧**：macOS 保留 78px 让位区；Windows 收窄为 12px 呼吸边（无交通灯概念）。
- **右侧新增 `_WindowControls`**（仅 Windows 渲染）：

```dart
// shell.dart 新增（示意）——window_manager legacy API 与 mac 端同源
Row(_WindowButton(icon: Icons.minimize, onTap: windowManager.minimize),
    _WindowButton(                       // isMaximized 状态切换 maximize/restore 图标
        icon: _maximized ? Icons.filter_none : Icons.crop_square,
        onTap: windowManager.toggleMaximize),
    _WindowButton(icon: Icons.close, hoverColor: 红系, onTap: windowManager.close))
```

- 最大化状态监听用 window_manager 的 `WindowListener`（`onWindowMaximize` / `onWindowUnmaximize`），不改全局结构（规避 shell 重建类坑，AGENTS.md 有 IndexedStack 前科）。
- 标题栏空白区**双击 = 切换最大化**（GestureDetector onDoubleTap，Windows 惯例）；拖拽仍走既有 DragToMoveArea。
- 窗口按钮热区按 Windows 惯例（约 46×32），close 悬停红底，其余悬停浅灰——与 macOS 视觉体系保持同源（Et 令牌取色）。
- **放弃的能力与补偿**：`hidden` 标题栏拿不到 Win11 snap-layouts 悬停面板，但窗口边缘 resize（native frame 保留）、Win+方向键 snap、Aero Shake 均为 OS 级行为不受影响；不值得为此上 WM_NCHITTEST 自定义命中（复杂度不成比例）。

### 4.3 main.dart 与既有桌面分支

`lib/main.dart:28-40` 已含 `Platform.isWindows`，`WindowOptions`（1280×800，min 960×640，hidden）对 Windows 直接生效；`windowButtonVisibility: true` 是 macOS-only 选项，Windows 忽略，无害。**预期此文件零改动**（除非 `_WindowControls` 需要把 isMaximized 状态提到全局，优先用 WindowListener 局部解决，不动这里）。

### 4.4 LKMK 与本地数据（P4 → D5）

- 零代码改动。Windows 上 `lkmk.bin`/`eterm.db` 落 `%APPDATA%\<CompanyName>\<ProductName>\`（path_provider_windows 由 exe VERSIONINFO 推导，具体值开工时核对，见核验项 #1）。
- 数据目录落位错误的最坏后果 = 重新登录 + 首拉（本地库可从中枢重建，见 §2.4），不构成数据风险。
- 运维修备注：杀软实时扫描对 `eterm.db`（WAL）有轻微 IO 放大，单用户体量可忽略；如遇锁冲突在杀软加排除目录即可。

### 4.5 功能对齐明细（D12）

| 功能面（mac 基线） | Windows 处置 | 备注 |
|---|---|---|
| 标题栏 + 侧栏壳（shell.dart） | **改造**：右侧补窗口控制钮、左让位区收窄 | §4.2 |
| Hosts 列表（搜索/分组/卡片/右键菜单） | 零改动 | 桌面右键 onSecondaryTapUp 逻辑天然可用 |
| 终端（xterm fork + 标签 pills + Ctrl±字号 + 右键菜单复制粘贴） | 零改动 | 字体已分支 Consolas；meta/control 快捷键按平台判定已就位；**IME 中文输入列入验收重点**（核验项 #3） |
| SFTP 三页（双侧浏览/传输面板/远端编辑） | 零改动 | 桌面「选本机根目录 + kv 记忆」路径在 Windows 直接生效（file_selector_windows 全 API 可用）；`.eterm-part` 断点续传是纯 Rust 文件逻辑，两端同源 |
| Keychain（生成/导入 PEM/部署公钥/Identity） | 零改动 | 导入走 openFile |
| 端口转发（local -L） | 零改动 | 防火墙弹窗预期见 P7/§8 |
| Known Hosts / Logs / Settings | 零改动 | 「重排键条」行有 Android-only 平台闸，Windows 不显示，符合预期 |
| 手机布局（<720 底部导航） | 不适用，代码保留 | 窗口最小 960 宽不可达；顺带规避 IndexedStack 重建 P1 |
| Android 前台服务保活（FgService） | 不适用 | 平台闸已是其他平台 no-op |
| 应用内更新（自动更新方案） | 并入（§6） | 依赖自动更新方案实施排期 |
| 托盘/开机自启/单实例 | 不做（D9/D10） | §11 |

---

## 5. 打包与安装器（D6）

`client/app/installer/eterm.nsis`（新增，手写，不引第三方打包工具）关键项：

```nsis
Unicode true
RequestExecutionLevel user            ; per-user 免 UAC
InstallDir "$LOCALAPPDATA\Programs\Eterm"

; HKCU 卸载登记（控制面板「应用和功能」可见）
; 开始菜单快捷方式；可选桌面快捷方式（组件页勾选）
; Section 内 File /r build\windows\x64\runner\Release\*   (Eterm.exe + flutter_windows.dll + 各插件 dll + rust_lib_eterm.dll)
; 卸载不删 %APPDATA% 数据（§2.5）
```

- 产物 `eterm-windows-setup.exe`，体积预估 60–90MB（Flutter Windows + Rust 库 + NSIS 压缩）。
- **VC++ 运行库**：Flutter Windows 产物动态链接 MSVC 运行时（vcruntime140/msvcp140），开发机必有但干净用户机可能缺失（启动即报缺 dll）。核验项 #7 在无开发工具的干净机器实测；缺失则安装器静默附带 `vc_redist.x64.exe`（已装则跳过）。
- 静默安装/卸载 `/S`；安装完成页（非静默时）可选「运行 Eterm」。
- 覆盖安装遇运行中 exe：手动场景在安装页提示先关闭应用；自动更新场景由流程保证（§6）。

## 6. 自动更新（D8，并入既有方案）

定位：Windows 作为第三端并入 [eterm-自动更新方案.md](eterm-自动更新方案.md)（该方案 v1.1 状态「已定未开发」）。实施本文时把该文档平台范围扩为三端，本节定义 Windows 侧差异，其余（nginx `/updates/`、`bump_build`、检查/下载/校验逻辑）全部复用。

| 环节 | Android（既有） | Windows（本文新增） |
|---|---|---|
| 元数据 | `eterm-android.json` | `eterm-windows.json`，schema 同构（version/build/url/sha256/size/notes） |
| 检查/下载/校验 | `app_update.dart`（dart:io + package:crypto） | **同一服务共用**，平台闸从 android 扩为 android‖windows；仅「安装」一步平台分支 |
| 安装 | PackageInstaller session | `Process.start(setup.exe, ['/S'], mode: detached)` → Dart `exit(0)` → NSIS 覆盖安装 → 安装器末段 `Exec "$INSTDIR\Eterm.exe"` 自动重启 |
| 用户交互 | 对话框「下载并安装」 | 对话框按钮文案改「退出并安装」（先退出再装的语义前置告知） |
| MotW | n/a | 应用内下载不落 Zone.Identifier，运行 setup 不叠加 SmartScreen（§2.6） |
| 失败语义 | 静默/轻提示，不碰主功能 | 同左 |

下载落盘：Windows 侧落 `getApplicationTemporaryDirectory()`（`%LOCALAPPDATA%\Temp`），固定文件名 `eterm-windows-setup.exe` 覆盖写；sha256 校验失败即删，不留半包。

会话安全：退出安装前走正常退出路径（kv/游标已即时持久化），无特殊处理；SFTP 传输若进行中，中断走 `.eterm-part` 暂存续传语义（可恢复），无需等待传输完成再退出。

## 7. 构建环境与发布脚本（D2/D11）

### 7.1 Windows 开发/构建机环境清单（同一台机器，D2）

| 组件 | 版本/说明 |
|---|---|
| 系统 | Windows 10+ **x64**（构建机与发布目标同架构） |
| Flutter SDK | 3.50 stable，**与 mac 端同版本**（脚本前置校验 `flutter --version`） |
| Visual Studio | 2022 Community + 「使用 C++ 的桌面开发」工作负载（MSVC v143 + Windows SDK） |
| Rust | rustup，`stable-x86_64-pc-windows-msvc` 工具链（cargokit 调 cargo，**必须 msvc 不用 gnu**） |
| NSIS | NSIS 3（Unicode） |
| Git | Git for Windows；源码经 git clone 到本机（gitee 远程）；本机 `git config core.autocrlf input`（防跨平台换行搅动 .sh/.nsis 脚本） |
| 网络工具 | OpenSSH client 与 curl（Windows 10+ 内置，scp 上传/回读校验用） |

### 7.2 `client/app/scripts/release_windows.ps1`（新增）

```powershell
# 0. 前置校验：git status 干净 + git pull --ff-only 最新——pubspec.yaml 是 build 号唯一
#    事实源，两台异机的发布脚本都须基于最新 pubspec bump，否则可能撞号
# 1. bump pubspec build 号（bump 语义内嵌本脚本，与自动更新方案 §9.1 的 lib_version.sh
#    同语义；注意 lib_version.sh 随该方案实施才新增，M3 时点先由本脚本承载）
# 2. flutter build windows --release
#    产物 build\windows\x64\runner\Release\
# 3. makensis installer\eterm.nsis → eterm-windows-setup.exe
# 4. Get-FileHash -Algorithm SHA256
# 5. scp 覆盖上传 setup + eterm-windows.json → root@YOUR_SERVER_IP:/opt/mao-data/uploads/eterm/
#    （磁盘紧张约定：覆盖同一文件，勿新增版本副本）
# 6. curl 公网回读 JSON，校验 version/build 与本次一致（对齐 release_android.sh 校验模式）
```

首次运行放开执行策略：`powershell -ExecutionPolicy Bypass -File scripts\release_windows.ps1`（或本机一次性 `Set-ExecutionPolicy RemoteSigned CurrentUser`）。

`docs/eterm-发布流程.md` 增补 Windows 发布小节；AGENTS.md 增补 Windows 常用命令与陷阱（JAVA_HOME 那条不适用 Windows，勿照搬）。

## 8. 测试策略

**门禁不变**（平台无关，继续在 mac 上跑）：`flutter analyze` 0 error；`flutter test` 全绿；`cd rust && cargo test --lib` 全绿（7 个）。

**Windows VM/构建机手工验收清单**（测试账号 `guitest` 直连生产中枢，目标主机 k7）：

| 域 | 用例 |
|---|---|
| 安装/启动 | NSIS 安装（免 UAC）→ 启动 → 升级覆盖安装 → 卸载（数据保留）→ 重装数据仍在；**中文/含空格用户名**下安装、启动、数据落位与 SFTP 选本机目录（%APPDATA%/%LOCALAPPDATA% 路径带中文/空格） |
| 同步 | 登录 → 首拉 → 主机/凭据/分组增删改 → 与 mac 端互同步（WS 实时 + 离线后增量） |
| 终端 | 连接 k7；**中文 IME 输入**（候选窗定位、全半角、Ctrl 组合键与输入法热键冲突）；Ctrl±/0 字号；右键复制粘贴；20000 行回滚；Consolas 渲染与中文回退 |
| SFTP | 上传/下载（含中文与含空格路径）；中断续传（`.eterm-part`）；冲突改名；远端编辑回传；跨盘/中文目录选根 |
| 端口转发 | 绑 127.0.0.1 规则起停（无防火墙弹窗）；绑 0.0.0.0 规则首次弹防火墙授权（P7 预期行为文档化） |
| 密钥 | 生成 Ed25519/导入 PEM/部署公钥到 k7 |
| TOFU | 首连确认指纹；known_hosts 设备级隔离（Windows 新设备需重新确认，预期行为） |
| 窗口 | min/max/close 三钮；双击标题栏最大化；Win+方向键 snap；边缘 resize；125%/150% HiDPI；深浅色跟随系统 |
| 更新（M4 后） | 旧版 → JSON 发现新版 → 下载 sha256 → 退出安装 → 自动重启 → 版本号变新；断网静默路径 |
| 杀软 | Defender 全开下首启/首连无拦截；若误报按 §10 缓解 |

## 9. 里程碑

| 阶段 | 内容 | 预估 |
|---|---|---|
| M0 | Windows 开发机环境就绪（D2，§7.1）+ `flutter create --platforms=windows` + 空壳跑起来（含 Rust/cargokit 接入） | 0.5–1 天 |
| M1 | 全功能零改动假设验证：按 §8 清单过一遍，产出「实际差异清单」 | 1–2 天 |
| M2 | Windows 化改造：标题栏三钮（§4.2）、图标、核验项清零、IME 等差异修复 | 1–2 天 |
| M3 | NSIS 安装器 + release_windows.ps1 + 发布流程/AGENTS 文档 | 1–2 天 |
| M4 | 应用内更新（并入自动更新方案实施排期，不单独排期） | 随自动更新方案 |

M0–M3 合计约 1 周（功能共享度决定的主要成本在环境与验收，不在编码）。

## 10. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| **无签名 exe 的杀软/SmartScreen 误报**（无证书 + 网络行为密集型应用是误报高发画像） | 高影响/中概率 | 应用内更新规避 MotW；发布产物固定命名与覆盖路径；误报时向微软提交申诉；D7 预留证书升级；发布文档明确「手动下载需右键/仍要运行」口径 |
| **终端 IME 在 Windows 的差异**（候选窗定位、组合键拦截） | 中 | vendor fork 有打补丁前科（DEL/宽字符），同路径修复；M1 尽早暴露 |
| NSIS 覆盖安装遇运行中 exe | 低 | 更新流程先退出（§6）；手动安装页提示 |
| `std::fs::rename` 在 Windows 的 sharing violation（目标被杀软扫描占用） | 低 | 下载本就走「暂存 + 改名」设计，重试可恢复；logs_page 可观测 |
| 单台 Windows 构建环境成单点 | 低 | 脚本 + 环境清单文档化，重建成本低；不引入 CI 是明确取舍 |
| path_provider 目录命名与预期不符 | 低 | 仅影响首次落位，数据可重建（§2.4）；核验项 #1 开工即核 |
| Flutter/Rust 工具链版本漂移（VM 与 mac 端不一致） | 低 | 发布脚本前置校验 Flutter 版本；AGENTS.md 记录环境锁定口径 |
| pubspec.lock 历史上未入库，Windows 机首次 `pub get` 曾可能独立解析漂移（本文引用的 file_selector_windows 0.9.3+6 等取自 mac 本机 lock） | 低 | **已拍板（D14）入库锁定**：`.gitignore` 已移除忽略行，下次任一端 `pub get` 生成首份 lock 并提交；后续依赖变更以 lock diff 审查（Rust 侧 Cargo.lock 本就入库） |

## 11. 明确不做

- **托盘 / 最小化到托盘 / 开机自启**（D9）——保持与 macOS 行为一致，避免新增平台语义。
- **单实例锁**（D10）——与 macOS 一致。
- **MSIX / Microsoft Store**（D6）——签名与分发机制与既有体系不合。
- **代码签名 / EV-OV 证书**（D7）——个人工具口径；将来需要再立项。
- **Windows ARM64 发布**（D3）——x64 仿真可用；确有需求再评估。
- **Win7 / Win8**——Flutter 桌面最低 Windows 10。
- **触屏/平板形态**——`<720` 手机布局在 Windows 不可达，不做 Surface 类触屏适配。
- **WM_NCHITTEST 原生标题栏命中测试**——只为 snap-layouts 悬停面板，不值得。
- **CI 自动构建**（GitHub Actions/Gitee Go）——手工脚本足够，见风险登记取舍。

## 12. 开工前核验项（不阻塞评审，M0 逐条出结论写回本文档）

1. `path_provider_windows` 实际落位：核对 `windows/runner/Runner.rc` 的 CompanyName/ProductName 与真实 `%APPDATA%` 路径（期望 `%APPDATA%\dev.eterm.eterm\eterm\` 一类；不符则改 rc，**不要**在 Dart 侧特判路径）。
2. 端口转发防火墙：实测绑 127.0.0.1 与 0.0.0.0 各自行为（portfw.rs:101 bind_addr 由规则配置传入）。
3. xterm fork 在 Windows 的 IME 细节：中文候选窗位置、全半角、输入法与 Ctrl 快捷键冲突。
4. NSIS Unicode + 中文安装文案 + 中文路径目录行为。
5. Defender 对未签名产物（exe/dll）首跑的启发式行为。
6. `flutter create --platforms=windows` 是否正确沿用 org（`dev.eterm`）生成 runner 元信息。
7. VC++ 运行库：无开发工具的干净 Windows 机器上验证产物直接启动（缺 vcruntime140/msvcp140 的表现），决定安装器是否附带 vc_redist.x64（§5）。
8. 旧版 Win10（长期未更新、可能缺 ISRG Root X1 根证书）登录中枢 TLS 是否正常（dart:io 在 Windows 走系统根证书库）；失败属系统级，提示更新系统即可。

---

## 附：实施时需改动/新增的文件清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `client/app/windows/*` | 新增 | `flutter create --platforms=windows` 生成后入库；核对 Runner.rc |
| `client/app/lib/ui/shell.dart` | 改 | `_TitleBar` 平台分支 + `_WindowControls` 三钮 + 双击最大化（§4.2） |
| `client/app/lib/main.dart` | 预期不改 | 桌面分支已含 Windows（§4.3）；仅当 maximized 监听无法局部化时微调 |
| `client/app/pubspec.yaml` | 改 | flutter_launcher_icons 增加 windows 段；（实施更新时）显式声明 `crypto`（沿用自动更新方案决定） |
| `client/app/assets/icon/` | 不改 | 源图复用 |
| `client/app/rust/`（全部） | **不改** | 含 keystore.rs（D5：仅可加一行注释说明 Windows 权限语义） |
| `client/app/installer/eterm.nsis` | 新增 | per-user NSIS 安装器（§5） |
| `client/app/scripts/release_windows.ps1` | 新增 | bump → build → pack → 上传 → 回读校验（§7.2） |
| `docs/eterm-发布流程.md` | 改 | 增补 Windows 发布小节 |
| `AGENTS.md` | 改 | Windows 常用命令与环境锁定口径段 |
| `docs/plan/eterm-自动更新方案.md` | 改（实施更新时） | 平台范围扩为三端 + Windows 安装小节（§6） |
