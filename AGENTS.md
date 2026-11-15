# AGENTS.md

自托管的主机与凭据数据中枢（eterm）+ 多端客户端。**架构铁律：客户端与目标服务器之间走本地直连（数据面），中枢只承载元数据同步（同步面），中枢永远不出现在数据面上。** 远程：`origin = git@gitee.com:yangjiayi/eterm.git`（main）。

## 目录

- `server/` — 中枢服务端，**Node 22 + TypeScript + Fastify 5 + mysql2**（⚠️ 根 README 与 Makefile 中的 Go 段落是过时遗留，以本文件为准）
- `client/app/` — Flutter 3.50 客户端（macOS 桌面 + Android）；`lib/`（Dart UI/services）+ `rust/`（Rust core：russh 0.46 SSH、rusqlite 本地库、aes-gcm 字段加密，经 flutter_rust_bridge 2.13 frb(sync) 暴露）
- `deploy/` — nginx/systemd/备份（生产：`eterm.etarch.cn`，root@120.26.109.221，systemd 单元 `eterm`，源码 /opt/eterm）
- `docs/` — PRD、技术方案、`eterm-发布流程.md`（改发布相关前必读）

## 常用命令

```bash
# server（在 server/ 下）
npm run typecheck && npm test        # vitest（无需 MySQL 的单测为主）
npm run dev / migrate / create-user  # 需 ETERM_DB_DSN + ETERM_PEPPER + ETERM_MASTER_KEY

# client/app（Flutter）
flutter analyze                      # 必须 0 error 再提交
flutter build macos --debug          # 桌面验证
flutter test / cd rust && cargo test --lib   # rust 测试 7 个

# Android 发布（覆盖上传到服务器，勿改约定）
client/app/scripts/release_android.sh        # 产物 sha256 双端校验
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
- 服务器磁盘紧张（~86%），APK 按 `docs/eterm-发布流程.md` 约定**覆盖同一文件**，大版本才留副本。

## 测试账号与环境

- 中枢测试账号：`guitest` / `eterm-GuiTest-2026!`（生产 eterm.etarch.cn）
- 测试主机：k7（120.26.109.221，root，私钥凭据已入库）；服务器 sshd `PasswordAuthentication no`
- SSH 密钥（发布/运维）：`~/Downloads/_my-aliyun-ecs-2026.pem`（`ETERM_SSH_KEY` 可覆盖）
