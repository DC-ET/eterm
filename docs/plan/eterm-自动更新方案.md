# eterm · 自动检查版本与更新方案（Android + macOS + Windows）

> 版本：v1.2 ｜ 日期：2026-11-21 ｜ 状态：**方案已定，未开发**（等排期）
> **v1.2 变更**（可行性复审 + Windows 客户端落地收编）：范围扩为 **三端**——Windows 侧设计收编自 [eterm-Windows客户端技术方案.md](eterm-Windows客户端技术方案.md) D7/D8/§6（已拍板），新增 §2.4/§4.3/§5.3/§9.5；§4 补 nginx `add_header` 继承修正，并标注 `/updates/` 已是 Windows 发布脚本（release_windows.ps1 回读校验）的**运行前置**；§6 剔除 FileProvider（PackageInstaller session 流不需要 content URI）；§9.1 改写为三端 bump 跨机不变式；§9.2 补 generate_appcast 私钥参数与产物改名；§4.2 示例 releaseNotesLink 改 `<description>`；§10 门禁数字更新（54）。
> **v1.1 变更**：应用户要求，范围从仅 Android 扩展为 **Android + macOS 双端**。macOS 走 Sparkle 2（appcast + EdDSA 签名 + zip），与 Android 共用同一套 nginx `/updates/` 静态分发；§1 新增前提问题 P4，§2/§4/§9 为双端口径，Android 侧设计（原 §5-§8）内容不变。
> 上游文档：[eterm-技术方案.md](eterm-技术方案.md)（下称技术方案）。本文只覆盖客户端自动更新这一个功能，不重复技术方案已论证的架构铁律。
> 关联：[eterm-发布流程.md](../eterm-发布流程.md)（发布约定；实施本文后需同步更新其中发布小节）。

---

## 1. 背景与问题

用户需求：客户端（安卓 + Mac + Windows）能自动检查新版本并完成更新。

勘察代码库后发现四个**必须先解决的前提问题**，它们共同决定了本方案的形态：

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1 | **安装包没有公开下载地址** | `deploy/nginx-example.conf` 把所有路径 `proxy_pass` 给中枢（127.0.0.1:8220），`/opt/mao-data/uploads/eterm/` 未对外暴露；安卓包一直靠微信/网盘手动传，Mac 包则只存在于本机 `build/` 目录 | 自动更新需要登录前可达的公网 HTTPS 分发点 |
| P2 | **Android targetSdk 是现代版本** | `client/app/android/app/build.gradle.kts` 用 `flutter.targetSdkVersion`，Flutter 3.50 默认为 **36**（`flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34`） | 老的 `ACTION_VIEW` + `application/vnd.android.package-archive` 静默安装路径在高版本不可靠，必须走 `PackageInstaller` session API |
| P3 | **versionCode 写死** | `client/app/pubspec.yaml:5` 为 `version: 1.0.0+1`，自 11-14 起未变 | Android 拒绝 versionCode 不增长的安装；macOS 的 `CFBundleVersion` 同样取自该 build 号（Sparkle 的 `sparkle:version` 必须递增）；Windows 的 exe 版本资源与 NSIS `-DVERSION` 亦同源。**三端发布脚本必须各自自动 +1，且共用一个 pubspec 事实源** |
| P4 | **macOS 应用是沙盒化的** | `macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements` 均有 `com.apple.security.app-sandbox = true` | Sparkle 1 不支持沙盒；Sparkle 2 可以，但必须启用框架内的 Installer XPC 服务并加 mach-lookup 例外 entitlement（见 §8） |

补充事实：`VERSION = "0.1.0-ts"` 硬编码在 `server/src/main.ts:14`，healthz 的版本号**不能**用于判断部署新旧（2026-11-20 已踩过：生产滞后三个 commit 但 healthz 显示正常）。

## 2. 决策记录（已与用户拍板）

### 2.1 三端共性

| 决策点 | 选择 | 理由 |
|---|---|---|
| 分发方式 | **nginx 静态目录** `/updates/`（三端共用） | 不动中枢代码、不重新部署服务端；检查更新在登录前、中枢宕机时也能工作；中枢只承载元数据同步面，不应再背应用分发职责 |
| 与中枢的关系 | 更新链路与中枢**完全解耦** | 检查失败一律静默或轻提示，绝不影响登录、同步、连接 |
| 版本号策略 | 共用 pubspec 的 `version: X.Y.Z+N`，发布脚本自动递增 | 单一事实源；Android versionCode / macOS CFBundleVersion / Windows exe 版本资源三端 build 号天然一致；每次 +1 在 git 里可审查 |
| 平台范围 | Android + macOS + Windows（v1.2 并入） | Linux 未构建，不在范围；Windows 按 [eterm-Windows客户端技术方案.md](eterm-Windows客户端技术方案.md) D8 并入本方案（其 §6 定义 Windows 差异，本方案 §2.4/§5.3 收编） |

### 2.2 Android 侧（v1.0 已定，v1.1 不变）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 更新交互 | **应用内下载并安装** | 下载进度 + sha256 校验 + 调起系统安装界面；保留系统安装确认（安全上必要），其余全自动 |
| 检查时机 | 启动静默检查（24h 节流）+ 设置页手动入口 | 不每次启动打扰；用户想查时随时可查 |
| 元数据格式 | `eterm-android.json` | 结构简单，`url` 字段内嵌 APK 地址便于迁移 |

### 2.3 macOS 侧（v1.1 新增）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 更新框架 | **Sparkle 2**（CocoaPods 集成） | macOS 应用外更新的唯一成熟方案；Sparkle 2 支持沙盒应用。项目 SPM 已全局关闭（AGENTS.md），但 `macos/Podfile` 早已启用 CocoaPods，不受影响 |
| 沙盒 | **保留沙盒** + 启用 Installer XPC 服务 + mach-lookup 例外 entitlement | 不为更新牺牲沙盒；Sparkle 2 官方支持该组合 |
| 分发格式 | **zip**（内含 `Eterm.app`）+ **appcast XML** | Sparkle 原生格式；`generate_appcast` 一条命令完成签名与 XML 生成，无需 dmg 工具链 |
| 签名 | **EdDSA**（Sparkle 自带密钥对），私钥落**文件** | 与 AGENTS.md「LKMK 主密钥走文件、不用 login keychain」的既有教训一致——`generate_keys` 默认把私钥存进登录钥匙串，必须用 `-x` 导出成文件供脚本使用，避免钥匙串 ACL 问题 |
| 更新 UI | **Sparkle 标准更新器界面** + 设置页「检查更新」手动入口 | 标准 UI 久经考验、零自研成本；手动入口与 Android 体验对齐（经 MethodChannel 调 `checkForUpdates()`） |
| 代码签名/公证 | **不做** Developer ID 签名与公证 | 应用本就是 debug key 签名的个人工具；Sparkle 靠 EdDSA 验证更新真实性。首次安装需右键打开（Gatekeeper），更新替换本机 .app 无此问题 |

### 2.4 Windows 侧（v1.2 并入；设计收编自 Windows 技术方案 D7/D8/§6，已拍板）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 更新交互 | 应用内下载 setup → 「退出并安装」→ NSIS `/S` 静默覆盖安装 → 安装器末段自动重启 | 与 Android 同构；安装器（installer/eterm.nsis）已内建静默重启+运行中检测+覆盖保留数据，零自研安装逻辑 |
| 元数据 | `eterm-windows.json`，schema 与 Android 同构（§4.3） | 三端共用同一套检查/下载/校验 Dart 代码 |
| 下载落盘 | `getApplicationTemporaryDirectory()`（%LOCALAPPDATA%\Temp）固定名覆盖写，校验失败即删 | 临时目录不占用户数据区；不留半包 |
| 代码签名 | 一期不做（应用内下载不落 MotW，运行 setup 不触发 SmartScreen） | 与 macOS ad-hoc 口径一致（Windows 方案 D7） |
| 排期 | M4，随本方案实施，不单独排期 | Windows 方案 §9 里程碑定义 |

已确认可复用的既有资产（避免新造轮子）：

| 资产 | 位置 | 用途 |
|---|---|---|
| `dart:io` 零依赖 HTTP 风格 | `client/app/lib/services/api_client.dart` | Android+Windows 侧检查/下载沿用，不加第三方网络库 |
| `package_info_plus` | 已在 `client/app/pubspec.yaml`；`client/app/lib/ui/settings_page.dart:44` 已用 | Android+Windows 读当前 version / buildNumber |
| `local.kvPut / local.kvGet` | `client/app/lib/src/rust/api/local.dart:49-55` | 节流时间戳持久化，三端可用（SFTP 目录记忆 `sftp.localRoot` 同款） |
| MethodChannel 原生 glue 模式 | `client/app/android/app/src/main/kotlin/dev/eterm/eterm/MainActivity.kt`（`eterm/fg` 前台服务） | Android 安装 intent 的 Dart→Kotlin 通道照此扩展 |
| `.eterm-part` 暂存 + 完成后改名 | `client/app/rust/src/api/sftp.rs`（约定见 AGENTS.md） | Android APK 下载沿用同款暂存约定 |
| CocoaPods | `client/app/macos/Podfile`（`use_frameworks!`，platform osx 12.0） | Sparkle 以 `pod 'Sparkle'` 接入，`flutter build macos` 自动 pod install |
| 发布脚本上传 + sha256 双端校验 | `client/app/scripts/release_android.sh` | 发布校验模式复用到 macOS 脚本 |

## 3. 总体架构

```
┌─────────────────────────── 服务器（YOUR_SERVER_IP）────────────────────────────┐
│  nginx (443)                                                                   │
│   location /updates/  ──alias──►  /opt/mao-data/uploads/eterm/                 │
│        ├── eterm-android.json / .apk  { version, build, sha256, url, ... }      │ ← Android 元数据 + 包
│        ├── eterm-mac.xml / .zip       appcast（EdDSA 签名）+ 内含 Eterm.app     │ ← macOS 元数据 + 包
│        └── eterm-windows.json / .exe  JSON（schema 同构）+ NSIS 安装器          │ ← Windows 元数据 + 包
│   location /  ──proxy──► 中枢 127.0.0.1:8220（不受影响）                         │
└──────────────────────────────────┬─────────────────────────────────────────────┘
                                   │ HTTPS（无鉴权）
            ┌─────────────────────┼─────────────────────┐
            ▼                     ▼                     ▼
┌──────────────────────┐ ┌──────────────────────┐ ┌────────────────────────────┐
│ Android 客户端        │ │ macOS 客户端         │ │ Windows 客户端             │
│ app_update.dart      │ │ Sparkle 2（Runner 内）│ │ app_update.dart（检查/下载  │
│  检查/下载/sha256/节流 │ │  · SUFeedURL → xml   │ │ /校验与 Android 同一实现）  │
│ settings_page 对话框  │ │  · EdDSA 公钥内嵌     │ │ 下载 setup → sha256 →     │
│ _Boot 启动静默检查    │ │  · Installer XPC 越沙 │ │ 「退出并安装」→ setup /S   │
│ PackageInstaller     │ │  · 标准 UI + 手动入口 │ │ → 静默装完自动重启         │
│  session 安装         │ │                      │ │ 无原生 glue（Process.start）│
└──────────────────────┘ └──────────────────────┘ └────────────────────────────┘
```

设计原则：

- **更新链路与中枢完全解耦（三端一致）**——检查失败（超时/非 200/畸形）一律静默或轻提示，绝不影响登录、同步、连接。
- **元数据内嵌包地址**（Android JSON 的 `url` / appcast enclosure 的 `url`）——将来包搬家只改元数据，不用发新客户端。
- **版本比较以 build 号为唯一权威**——它是三端的安装闸门；version 字符串仅用于展示。
- **三端共用一套检查/下载/校验纯逻辑**（`isNewer`/`shouldCheck`/sha256），仅「安装」一步按平台分支——Android PackageInstaller session、Windows NSIS 静默安装器、macOS Sparkle Installer XPC。
- **EdDSA 私钥落文件**，与 AGENTS.md「不用 login keychain」的既有教训一致。

## 4. 分发基础设施（nginx，三端共用）

`deploy/nginx-example.conf` 的 443 server 块内，在 `location /` **之前**加（前缀 location 优先于 `/`）：

```nginx
# 客户端自动更新分发：版本元数据 + 安装包静态可读（无鉴权，登录前/中枢宕机时也能检查）
# 注意 nginx add_header 继承规则：location 内一旦出现自己的 add_header，
# server 级三条安全响应头（HSTS / X-Content-Type-Options / Referrer-Policy）
# 对本 location 不再继承——必须在此重复声明，否则 /updates/ 响应裸奔。
location /updates/ {
    alias /opt/mao-data/uploads/eterm/;
    add_header Cache-Control "no-cache" always;   # 元数据（JSON/appcast）不缓存
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
```

线上生效步骤：改 `/etc/nginx/` 下对应 conf → `nginx -t` → `systemctl reload nginx`。80 端口的 `return 301 https://...` 已覆盖 `/updates/`，无需额外配置。

> **v1.2 前置依赖警示**：该 location 已不只是「更新功能的前置」——Windows 发布脚本 `release_windows.ps1` 第 6 步会 `curl https://hub.example.com/updates/eterm-windows.json` 公网回读校验，在 `/updates/` 未生效前该请求被 `location /` proxy 给中枢 → 404 → 发布中断。即 nginx 改动是 **Windows 真实发布的阻塞前置**（`-NoUpload` 本地演练不受影响，见 §9.5）。

### 4.1 Android 元数据 schema

`eterm-android.json`（随每次发布由脚本生成并上传）：

```json
{
  "version": "1.0.2",
  "build": 3,
  "url": "https://hub.example.com/updates/eterm-android.apk",
  "sha256": "<APK 完整 sha256>",
  "size": 79075407,
  "published_at": "2026-11-20T13:00:00+08:00",
  "notes": "修复导入密钥对话框崩溃；搜索框去双重边框"
}
```

| 字段 | 用途 | 备注 |
|---|---|---|
| `version` / `build` | 版本展示 + 新旧判定 | `build` 即 versionCode，判定唯一权威 |
| `url` | APK 下载地址 | 写绝对 URL，便于将来迁移 |
| `sha256` | 下载完整性校验 | 防截断/损坏；同源 HTTPS 下不做真实性论证 |
| `size` | 下载前展示 | 可选 |
| `notes` | 更新说明 | 默认取 `git log -1 --pretty=%s`，脚本支持 `--notes "..."` 覆盖 |

### 4.2 macOS appcast

`eterm-mac.xml`（由 Sparkle 的 `generate_appcast` 生成）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Eterm</title>
    <item>
      <title>Eterm 1.0.2</title>
      <description>修复导入密钥对话框崩溃；搜索框去双重边框</description>
      <pubDate>Thu, 20 Nov 2026 05:00:00 +0000</pubDate>
      <sparkle:version>3</sparkle:version>
      <sparkle:shortVersionString>1.0.2</sparkle:shortVersionString>
      <enclosure url="https://hub.example.com/updates/eterm-mac.zip"
                 length="28411520" type="application/octet-stream"
                 sparkle:edSignature="<EdDSA 签名>"/>
    </item>
  </channel>
</rss>
```

要点：
- `sparkle:version` = build 号（CFBundleVersion），**必须递增**（P3）。
- `sparkle:edSignature` 由 `sign_update`/`generate_appcast` 用私钥对 zip 生成。
- release notes：一期用 `<description>` 内嵌纯文本（v1.1 示例曾误用 `sparkle:releaseNotesLink` 指向一个没有任何脚本会生成的 HTML 文件，v1.2 已改；`<description>` 由发布脚本注入，见 §9.2）；**不要启用 Downloader XPC 服务**（应用已有 `network.client` entitlement），否则 Sparkle 会退回废弃的 WebKit 渲染 release notes 且不支持版本自适应 notes。

### 4.3 Windows 元数据 schema（v1.2 增补）

`eterm-windows.json`：字段与 §4.1 **完全同构**（version/build/url/sha256/size/notes），`url` 指向 `/updates/eterm-windows-setup.exe`。`release_windows.ps1` 已按此 schema 生成并覆盖上传；因 `/updates/` location 尚未上线，真实发布尚未跑通（pubspec 仍为 1.0.0+1，git 无 `release: windows` 提交），`notes` 暂为空串占位（§9.5）。

## 5. Android 与 Windows 客户端设计（Dart 侧共用）

### 5.1 Dart 服务 `client/app/lib/services/app_update.dart`（新增）

```dart
class UpdateInfo {
  final String version;   // "1.0.2" 展示用
  final int build;        // versionCode，判定权威
  final String url;
  final String sha256;
  final int size;
  final String notes;
  final String publishedAt;
}

// 纯函数（单测覆盖）：versionCode 大才叫新；相等/更小 → 不更新
bool isNewer(UpdateInfo info, {required int currentBuild});

// 节流纯函数（单测覆盖）：距上次检查不足 interval 则不查
bool shouldCheck({required int lastCheckMs, required int nowMs, Duration interval = 24h});

Future<UpdateInfo?> check();   // GET JSON，8s 超时；非 200/畸形/缺字段 → null
Future<String> download(UpdateInfo info, {void Function(int, int)? onProgress});
                                // 流式写 <外部files>/update/eterm-<version>-<build>.apk.eterm-part，
                                // 完成改名 + sha256 校验；取消则删暂存
```

- HTTP 用 `dart:io` `HttpClient`，风格对齐 `api_client.dart`（零第三方依赖）。
- sha256 用 `package:crypto`（构建日志显示其已在依赖树中；需在 `pubspec.yaml` **显式声明**，不依赖传递依赖）。
- 下载目录 `getExternalStorageDirectory()/update/`，即 `Android/data/<pkg>/files/update/`——应用专属外部目录，免运行时权限（与 SFTP 下载落盘约定一致）。
- 节流时间戳：`local.kvPut(key: 'app.update.last_check', value: '<epoch ms>')`。
- 平台闸（v1.2 扩为 android‖windows）：`defaultTargetPlatform` 为 android 或 windows 时启用，macOS 等其余平台一律返回 null；「安装」一步按平台分支——Android 走 §6 原生通道，Windows 走 §5.3。

### 5.2 UI（`client/app/lib/ui/settings_page.dart` + `client/app/lib/main.dart`）

**设置页 · 关于卡**：在现有版本信息下加「检查更新」行（复用卡内既有行样式）。

状态机：

| 状态 | 表现 |
|---|---|
| 检查中 | 行内 spinner |
| 已是最新 | SnackBar「已是最新版本 vX.Y.Z」 |
| 有新版本 | 对话框：新版本号 / notes / 大小 / [取消] [下载并安装] |
| 检查失败 | SnackBar「检查更新失败」（不阻塞，可重试） |
| 下载中 | 对话框：LinearProgressIndicator + [取消] |
| 校验失败 | SnackBar 明确报错，删除暂存文件 |
| 需安装权限 | 对话框引导「设置 → 允许安装未知应用」，授权后重试（仅 Android；Windows 无此状态） |

**启动静默检查**（`_Boot` 进入主壳之后，`client/app/lib/main.dart`）：Android + Windows、24h 节流、静默 `check()`；发现新版本用**非模态 SnackBar**（「发现新版本 vX.Y.Z」+ 更新 action 打开同一对话框）——不用启动弹窗，避免每次打开应用都打断。macOS 不走此路径（Sparkle 自带启动自动检查，§7.4）。Windows 对话框按钮文案为「退出并安装」（先退出再装的语义前置告知，§5.3）。

### 5.3 Windows 侧（v1.2 并入，收编自 Windows 技术方案 §6/D8）

Windows 与 Android **共用 `app_update.dart` 的检查/下载/校验/节流**（同一 JSON schema、同一 `isNewer`/`shouldCheck`/sha256），仅「安装」一步平台分支，且**无任何原生 glue**：

- 元数据 `eterm-windows.json`（§4.3），检查逻辑同 `check()`，仅 URL 换为 `/updates/eterm-windows.json`。
- 下载落盘：`path_provider` 的 `getApplicationTemporaryDirectory()`（%LOCALAPPDATA%\Temp），固定文件名 `eterm-windows-setup.exe` 覆盖写，沿用 `.eterm-part` 暂存 + 完成改名约定；sha256 校验失败即删，不留半包。
- 安装时序（固定不变式）：确认对话框「退出并安装」→ `Process.start(setup, ['/S'], mode: detached)` → Dart `exit(0)`（spawn 后延迟 ~500ms 给安装器自解压留窗口，兜底竞态；kv/游标已即时持久化，无需等待 SFTP 传输——中断走 `.eterm-part` 续传语义）→ NSIS 静默覆盖安装 → 安装器末段 `Exec '"$INSTDIR\Eterm.exe"'` 自动重启。安装器侧零改动（静默 /S + 覆盖安装 + 自动重启均已内建，见 `installer/eterm.nsis`）。
- 竞态要点：静默模式会**跳过**安装器的运行中检测（`.onInit` 里 `IfSilent done`），依赖流程保证「spawn 后立即退出」；若 exe 未完全退出，覆盖安装会失败。spawn 与 exit 间隔百 ms 级，安装器自解压先于写文件，窗口极小，e2e 验证兜底（§11.8）。
- MotW：应用内下载（dart:io 直写文件）不落 Zone.Identifier，运行 setup 不叠加 SmartScreen 弹窗（Windows 方案 §2.6/D7 口径）；免 UAC（安装器 `RequestExecutionLevel user` per-user 安装）。
- 节流时间戳同样走 `local.kvPut`（Rust 本地库跨平台，Windows 可用）。

## 6. Android 原生设计

### 6.1 清单（v1.2 修正：不再引入 FileProvider）

`client/app/android/app/src/main/AndroidManifest.xml`（主清单；INTERNET 等既有权限不动，AGENTS.md 有删权限导致真机 DNS 失败的前科）：

```xml
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```

v1.1 曾计划同时加 FileProvider + `file_paths.xml` 并在安装时序里先生成 content URI——那是 `ACTION_VIEW` 安装路径的产物，与本方案选定的 PackageInstaller session 路径（§6.2：APK 字节经 `openWrite` 直接流入 session）无关，属文档残留，v1.2 剔除。少一个 provider 少一分 manifest 面。

### 6.2 安装通道（`MainActivity.kt`，新 channel `eterm/update`）

`installApk(path)` 时序：

1. Android 8+ 查 `packageManager.canRequestPackageInstalls()`；未授权 → 跳 `ACTION_MANAGE_UNKNOWN_APP_SOURCES`（`package:` URI），向 Dart 回 `need_permission`（Dart 出引导对话框，用户授权后重试）。
2. 已授权 → **PackageInstaller session**：
   - `createSession(SessionParams(MODE_FULL_INSTALL))` → `openWrite` 把 APK 字节流入 session → `fsync` → `commit(intentSender)`
   - `intentSender` 来自 `PendingIntent.getBroadcast(...)`，**必须 `FLAG_MUTABLE`**（Android 12+ 强制的是显式声明 mutability；系统经 fill-in 写入 `EXTRA_STATUS`，IMMUTABLE 会静默丢 extras → 永远误报失败。初稿误写 FLAG_IMMUTABLE，2026-11-21 评审修正）
   - 79MB 拷贝/commit 全程放后台线程（MethodChannel handler 默认主线程，会 ANR）；失败路径 `session.abandon()` 清残留
   - 系统弹出安装确认界面；用户点安装后完成
3. 新增小型 `UpdateInstallReceiver`（channel 用实例字段持有，companion 会跨 engine 重建持陈旧引用）：
   - 先处理 **`STATUS_PENDING_USER_ACTION`**：其 `EXTRA_INTENT` 携带系统安装确认界面 intent，**必须 `startActivity` 拉起**——不处理则确认界面永远不弹、流程停摆（2026-11-21 评审补充）
   - 最终 `STATUS_SUCCESS` / `STATUS_FAILURE*` 才经 MethodChannel 回传 Dart（成功/失败 → SnackBar）。没有这一步安装失败将完全静默。

> 选 PackageInstaller 而非 `ACTION_VIEW` + `application/vnd.android.package-archive`：后者在 targetSdk 29+ 上行为不可靠（见 P2）。session 路径全程不需要 FileProvider/content URI（v1.2 已剔除 §6.1 的相关残留）。

## 7. macOS 客户端设计（Sparkle 2）

### 7.1 依赖接入（CocoaPods）

`client/app/macos/Podfile` 的 `target 'Runner'` 内加：

```ruby
pod 'Sparkle'
```

`flutter build macos --release` 会自动执行 pod install（Flutter macOS 构建已集成 CocoaPods；与全局关闭的 SPM 无关）。

### 7.2 Info.plist 键（`macos/Runner/Info.plist`）

| 键 | 值 | 说明 |
|---|---|---|
| `SUFeedURL` | `https://hub.example.com/updates/eterm-mac.xml` | appcast 地址；Sparkle 按此自动检查 |
| `SUPublicEDKey` | `<EdDSA 公钥>` | 由 `generate_keys` 生成；每个分发包都要内嵌 |
| `SUEnableInstallerLauncherService` | `YES` | **沙盒应用必需**：让 Installer XPC 越出沙盒替换 .app |

### 7.3 entitlements（`DebugProfile.entitlements` / `Release.entitlements`）

保留 `com.apple.security.app-sandbox` 等既有键不变，新增 mach-lookup 例外（Sparkle Installer XPC 的两个 Mach 服务名，Xcode 会自动替换 bundle id 变量）：

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

> 应用已有 `com.apple.security.network.client`，**不要**启用 `SUEnableDownloaderService`——否则 Sparkle 会退回废弃的 WebKit 渲染 release notes，且丧失版本自适应 notes 能力。

### 7.4 Runner 侧初始化（`macos/Runner/AppDelegate.swift`）

```swift
import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 设置页「检查更新」入口（Dart → MethodChannel "eterm/update" → checkForUpdates）
    MethodChannel(FlutterViewController...)...
  }
}
```

- `SPUStandardUpdaterController` 自带标准更新器界面（检查 → 下载 → 「安装并重启」），零自研 UI。
- 自动检查间隔用 Sparkle 默认（每天一次）；用户侧无需配置。

### 7.5 设置页手动入口（Dart → MethodChannel）

`lib/ui/settings_page.dart` 关于卡内「检查更新」行 → `MethodChannel('eterm/update').invokeMethod('checkForUpdates')` → AppDelegate 转 `updaterController.checkForUpdates(nil)`；Sparkle 的界面会告知「已是最新」或展示新版本。与 Android 的差异：macOS 的 UI 由 Sparkle 提供，Dart 只负责触发。

### 7.6 更新替换的路径语义

Installer XPC 替换的是**当前运行的 `.app` 所在路径**：

- 正式用法：把 `Eterm.app` 放进 `/Applications`（或 `~/Applications`），之后更新原地替换。
- 开发期从 `client/app/build/macos/Build/Products/Release/` 直接跑时，更新会替换该构建产物目录里的 .app——语义正确但会被下次 `flutter build` 覆盖，属正常现象，不影响验证更新链路本身。

## 8. macOS 原生设计要点与坑

| 项 | 要求 |
|---|---|
| Sparkle 版本 | **2.x**（Sparkle 1 不支持沙盒） |
| XPC 服务 | 沙盒应用必须启用 Installer 服务；其 `Autoupdate` / `Updater.app` / `Sparkle.framework` 由 CocoaPods 自动带入 |
| 自签名时的顺序 | 若将来脱离 Xcode Archive 流程自行签名，必须按 `Installer.xpc` → `Downloader.xpc` → `Autoupdate` → `Updater.app` → `Sparkle.framework` → 主 app 的顺序签名；**禁用 `--deep`**（Sparkle 文档称其为沙盒报错的常见来源） |
| 调试注意 | 分布式 XPC 服务启用 Hardened Runtime，Xcode 内调试可能失败；需关闭 scheme 的「Debug XPC services used by app」或脱离 Xcode 运行 |
| Library Validation | 项目未启用；若将来启用，本地签名需 Apple Development 证书（Sparkle 文档明示） |

## 9. 发布脚本（三端）

### 9.1 三端 build 号递增（v1.2 改写：跨机不变式，对齐 release_windows.ps1）

`pubspec.yaml` 的 `version: X.Y.Z+N` 是三端唯一事实源（Android versionCode / macOS CFBundleVersion / Windows exe 版本资源与 NSIS `-DVERSION`）。build 号会在**两台异机构建机**（mac 跑 android/macos 脚本，Windows 机跑 release_windows.ps1）上先后 bump，必须遵守 release_windows.ps1 已落地的不变式（Windows 方案 §7.2）：

- **发布前置**：工作区干净 + `git pull --ff-only`——bump 必须基于最新 pubspec，否则跨机撞号
- **上传校验通过后**：脚本自动 `git commit + push` bump 结果——另一台机器下次发布才能拿到新 build 号；只 bump 不 commit 等于没 bump
- bump 语义各自内嵌：mac 侧抽 `lib_version.sh`（提供 `bump_build()`：读 pubspec → 回写 N+1 → 回显新版本号）供 release_android.sh / release_macos.sh source；Windows 侧 PowerShell 无法 source bash，release_windows.ps1 内嵌同语义实现（正则口径一致）
- 任一端发布让 N 前进，其余两端下次发布的元数据自然带上更大 `build`/`sparkle:version`——**这正是想要的**（三端版本单调一致）
- 现状：release_windows.ps1 已具备上述全部；release_android.sh 尚未改造（目前不 bump、不生成 JSON、无前置校验），release_macos.sh 未建——实施时两个 mac 脚本必须补齐同款不变式

### 9.2 `client/app/scripts/release_macos.sh`（新增）

```bash
# 1. bump_build（共用 helper）
# 2. flutter build macos --release            # 产物 build/macos/Build/Products/Release/Eterm.app
# 3. ditto -c -k --sequesterRsrc --keepParent Eterm.app eterm-mac.zip
# 4. 在仅含该 zip 的暂存目录跑 Sparkle 的 generate_appcast，签名私钥走文件（不落钥匙串，§9.3）：
#      generate_appcast --ed-key-file "$ETERM_SPARKLE_PRIVATE_KEY" \
#        --download-url-prefix https://hub.example.com/updates/ <暂存目录>
#    → 产物默认名 appcast.xml（内含 edSignature/length/version），脚本重命名为 eterm-mac.xml
#      （暂存目录只放新 zip，避免顺带生成 delta 更新）
# 4.5 用 python3 往 item 注入 <description>（内容取 git log -1 --pretty=%s，转义交给
#     xml.sax.saxutils.escape——与 §9.4 的 json.dumps 同理，不手拼标记）
# 5. scp 上传 eterm-mac.zip + eterm-mac.xml（覆盖）→ 上传校验通过后 commit+push bump（§9.1）
# 6. 校验：sha256 双端一致 + curl 回读 appcast 校验 version/build
```

Sparkle 工具位置（pod install 后）：`client/app/macos/Pods/Sparkle/bin/{generate_keys,generate_appcast,sign_update}`。

### 9.3 EdDSA 密钥管理

```bash
# 一次性：生成密钥对（默认会把私钥写进登录钥匙串）
macos/Pods/Sparkle/bin/generate_keys
# 立即导出成文件（与 AGENTS.md「主密钥走文件、不用 login keychain」同一教训），
# 私钥文件放 ~/Downloads/ 或项目外，脚本用 ETERM_SPARKLE_PRIVATE_KEY 指向，权限 0600
macos/Pods/Sparkle/bin/generate_keys -x ~/Downloads/eterm-sparkle-ed25519
```

公钥内嵌 `Info.plist` 的 `SUPublicEDKey`；私钥只存在于那一个文件，脚本签名时读取。**私钥丢失 = 永远无法再给该 app 发更新**（换钥 = 换 bundle id 重新首发），备份建议纳入发布流程自检。

### 9.4 Android 脚本改动（`release_android.sh`，v1.0 已定）

1. **自动递增 versionCode**：改调共用 `bump_build()`。
2. 构建（JAVA_HOME 钉 JDK17 的既有逻辑不动）。
3. 生成 JSON：`sha256` 用 `shasum -a 256`；**用 python3 `json.dumps` 序列化**（提交标题常含中文引号，手拼 JSON 会转义出错）。
4. scp 上传 APK + JSON（覆盖，沿用磁盘约定）。
5. 校验：保留 APK sha256 双端校验；**新增通过公网 URL `curl` 回读 JSON，校验 version/build 与本次发布一致**——走客户端真实请求路径，顺带验证 nginx location 生效。

### 9.5 Windows 发布脚本（v1.2 增补：已落地，`release_windows.ps1` 现状与约束）

Windows 发布流程已随 Windows 客户端落地（427860b），相对本方案 v1.1 的新事实：

- 已按三端 schema 生成 `eterm-windows.json` 并覆盖上传（`notes` 现为空串占位）；前置校验（工作区干净 + `pull --ff-only`）、bump 内嵌、上传后自动 commit+push 均已具备——即 §9.1 不变式的**样板实现**。
- **公网回读校验（脚本第 6 步）依赖 §4 的 `/updates/` location 先行生效**：生产 nginx 尚无该 location，/updates/* 会被 `location /` proxy 给中枢 → 404 → `curl -f` 失败 → 发布中断。即本方案的 nginx 改动已是 Windows 真实发布的**阻塞前置**（`-NoUpload` 本地演练不受影响；pubspec 仍为 1.0.0+1 也说明真实发布尚未跑通）。
- 客户端应用内更新逻辑见 §5.3；实施本方案时该脚本本身无需改动（可选：把 `notes` 从空串改为 `git log -1 --pretty=%s`，与 Android JSON 口径一致，写文件沿用脚本内 NoBomWrite）。

## 10. 测试策略

**Dart 单测**（`client/app/test/app_update_test.dart`，纯函数、无网络无 FFI，对齐现有测试风格；三端共用同一套逻辑，Windows 分支天然被同套用例覆盖）：

- `isNewer`：build 大于 / 等于 / 小于当前，三种
- JSON 解析：合法 / 缺必填字段 / 畸形 / 空响应
- sha256 校验函数：匹配 / 不匹配
- `shouldCheck`：恰好 24h、超过 1ms、首次（无记录）

**门禁**：`flutter analyze` 0 error；`flutter test` 全绿（含现有 54 个，427860b 时点）。

**macOS 侧**：Sparkle 的检查/下载/安装逻辑在框架内，无单测基建；靠真机端到端覆盖。**Android 侧**：原生 Kotlin 无测试基建，同样靠真机。**Windows 侧**：安装一步（spawn setup + 退出 + 静默重启）与 NSIS 链路无测试基建，靠 Windows 机端到端覆盖（Windows 方案 §8「更新（M4 后）」行）。

## 11. 上线顺序与端到端验证

1. **nginx conf 先行**入库（`deploy/nginx-example.conf`）→ 线上 `nginx -t` + reload → `curl` 验证 `/updates/` 可回读。注意：这一步同时是 **Windows 发布脚本的前置**（release_windows.ps1 公网回读校验在 `/updates/` 未生效前必然失败，§9.5）。
2. 抽 `bump_build` helper（§9.1 三端口径）；改 `release_android.sh`（补前置校验 + bump + JSON 生成上传 + 上传后 commit/push + 回读校验），新增 `release_macos.sh` → **先不发布**。
3. 实现客户端全部代码（Android Dart/原生 + Windows Dart 分支 §5.3 + macOS Sparkle 集成 + 共用 helper），过门禁。
4. **先发 macOS**（自测成本低）：跑 `release_macos.sh` → 发布 zip + appcast。
5. macOS 端到端：
   - 把上一个 build 的 `Eterm.app` 装进 `/Applications` → 打开 → Sparkle 提示新版本 → 安装并重启 → 版本号变新
   - 再打开 → 「已是最新」
   - 降级路径：断网启动 → 静默无提示；设置页手动检查 → Sparkle 提示检查失败
   - 私钥/签名路径：篡改 zip 后重新生成 appcast 用错签名 → Sparkle 拒绝安装（验证 EdDSA 真的在生效）
6. **再发 Android**：跑 `release_android.sh` → 发布 APK + JSON。
7. Android 端到端（关键：用「旧包升新包」的真实路径）：
   - 把第 6 步之前的旧 APK（versionCode 更小）装到手机
   - 打开 → 「发现新版本」SnackBar → 点更新 → 下载进度 → 系统安装界面 → 安装完成
   - 再打开 → 「已是最新」
   - 降级路径：飞行模式启动 → 静默；手动检查 → 「检查更新失败」SnackBar
   - 权限路径：关掉「允许安装未知应用」→ 引导对话框 → 授权后继续安装
8. **Windows（M4，随本方案实施）**：跑 `release_windows.ps1`（nginx 已先行，回读校验应通过）→ 端到端：
   - 旧 setup（build 更小）安装 → 打开 → 「发现新版本」SnackBar → 「退出并安装」→ 应用退出 → 静默安装 → 自动重启 → 版本号变新
   - 再打开 → 「已是最新」
   - 降级路径：断网启动 → 静默；篡改 JSON 的 sha256 → 下载后校验失败拒装并删暂存
   - 中文/含空格用户名的机器走一遍更新安装路径（%LOCALAPPDATA%\Temp 落盘 + 覆盖安装，Windows 方案 §8 已有先例口径）
9. 更新 `docs/eterm-发布流程.md`（三端发布 + build 号自动递增不变式 + 自动更新分发小节 + EdDSA 私钥备份提醒）后提交推送。

## 12. 风险登记

| 风险 | 缓解 |
|---|---|
| **EdDSA 私钥丢失/损坏** | 之后无法再发更新（换钥=换 bundle id 重新首发）；私钥文件 0600 + 纳入发布自检清单 + 异地备份 |
| APK / zip / setup.exe 公网可下载（原本只经微信/网盘小范围传播） | 本就是 debug key 签名的个人工具包，公开可下载可接受；URL 不含敏感信息 |
| 沙盒 + XPC 集成踩坑（Sparkle 文档称沙盒报错多源于签名） | 走 CocoaPods 默认嵌入，不自签名、不用 `--deep`；按 §8 清单逐项核对 |
| Sparkle 更新替换的是运行中的 .app，开发期目录被 build 覆盖 | 语义正确、不影响链路验证；正式使用约定放 `/Applications`（见 §7.6） |
| 三端 build 号竞态/漏递增（跨两台构建机） | 共用事实源 + bump 后自动 commit/push（§9.1 不变式）；每次发布有可审查 diff |
| versionCode 忘递增导致装不上 | 脚本自动 +1，不靠人记 |
| 下载中断留下大暂存文件 | Android：`.eterm-part` + 取消即删 + 安装成功后清理 update 目录 |
| 检查请求被中间人篡改 | HTTPS + 双保险（Android/Windows sha256 校验 / macOS EdDSA 签名）；元数据与包同源 |
| nginx `alias` 路径配置错误 | `nginx -t` + 上线后立即 `curl` 公网 URL 验证（脚本的校验步骤已内置） |
| Windows 静默安装与退出竞态：`/S` 跳过安装器运行中检测（eterm.nsis `.onInit` `IfSilent done`），exe 未完全退出时覆盖安装会失败 | spawn detached 后立即 `exit(0)`，竞态窗口百 ms 级（安装器自解压先于写文件）；e2e 验证兜底；若复现，安装器侧补静默等待重试 |
| mac 侧脚本 bump 后漏 commit/push → Windows 机下次发布基于陈旧 pubspec 撞号 | §9.1 三端不变式：上传校验通过后自动 commit+push + 前置 clean + `pull --ff-only`（release_android.sh / release_macos.sh 实施时补齐，对齐 release_windows.ps1 既有行为） |

## 13. 明确不做

- **增量更新 / 断点续传**——Android 79MB 全量可接受（`.eterm-part` 已为将来续传留好形状）；macOS delta 更新同理（`generate_appcast` 暂存目录只放新 zip，不生成 delta）。
- **更新通道 / 灰度 / 强制更新**——单用户个人项目，一个元数据文件足够；需要时在 JSON/appcast 加 `min_build` 字段即可扩展。
- **中枢提供更新元数据路由**——已评估否决：包终究要 nginx 暴露静态目录，绕不开；且让中枢多背一份非同步面职责。
- **Developer ID 签名 / 公证 / dmg 分发**——macOS 保持 ad-hoc（debug key）签名 + zip；首次安装需右键打开（Gatekeeper）。将来若要正式分发再立项，届时 Sparkle 的 EdDSA 机制不变。
- **Linux**——未构建。Windows 已落地（427860b）并按 Windows 技术方案 D8 并入本方案三端体系（§2.4/§4.3/§5.3/§9.5），应用内更新为 M4 随本方案排期。

---

## 附：实施时需改动/新增的文件清单

| 文件 | 动作 | 端 |
|---|---|---|
| `deploy/nginx-example.conf` | 改（加 `/updates/` location，含安全头重复声明 §4；Windows 发布阻塞前置 §9.5） | 三端共用 |
| `client/app/scripts/lib_version.sh` | 新增（`bump_build` helper，供 mac 侧两脚本 source；Windows 内嵌同语义 bump §9.1） | Android+macOS |
| `client/app/scripts/release_android.sh` | 改（前置校验 + 调共用 bump + JSON 生成上传 + 回读校验 + 上传后 commit/push） | Android |
| `client/app/scripts/release_macos.sh` | 新增（build → zip → generate_appcast → 上传 → 校验 → commit/push） | macOS |
| `client/app/scripts/release_windows.ps1` | **已落地，无需改动**（bump/JSON/回读校验/commit+push 均已具备 §9.5；实施时可选把 notes 空串改 git log） | Windows |
| `client/app/lib/services/app_update.dart` | 新增（检查/下载/sha256/节流三端共用；安装分支：Android 原生通道 / Windows §5.3） | Android+Windows |
| `client/app/lib/ui/settings_page.dart` | 改（检查更新行；Android/Windows 对话框状态机 + macOS 触发 Sparkle） | 三端 |
| `client/app/lib/main.dart` | 改（Android+Windows 启动静默检查挂点） | Android+Windows |
| `client/app/android/app/src/main/AndroidManifest.xml` | 改（仅加 REQUEST_INSTALL_PACKAGES；不加 FileProvider，session 流不需要 §6.1） | Android |
| `client/app/android/app/src/main/kotlin/dev/eterm/eterm/MainActivity.kt` | 改（`eterm/update` channel + installApk + Receiver） | Android |
| `client/app/macos/Podfile` | 改（`pod 'Sparkle'`） | macOS |
| `client/app/macos/Runner/Info.plist` | 改（SUFeedURL / SUPublicEDKey / SUEnableInstallerLauncherService） | macOS |
| `client/app/macos/Runner/DebugProfile.entitlements`、`Release.entitlements` | 改（mach-lookup 例外） | macOS |
| `client/app/macos/Runner/AppDelegate.swift` | 改（SPUStandardUpdaterController + `eterm/update` channel） | macOS |
| `client/app/pubspec.yaml` | 改（显式声明 `crypto`） | Android+Windows |
| `client/app/test/app_update_test.dart` | 新增（纯函数，三端同套覆盖） | Android+Windows |
| `client/app/installer/eterm.nsis` | 不动（静默 /S + 覆盖安装 + 自动重启已内建，§5.3） | Windows |
| `docs/eterm-发布流程.md` | 改（三端发布 + 自动更新分发 + 私钥备份） | 三端共用 |
