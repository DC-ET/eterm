# eterm · 产品设计与需求文档 v2.0

> 版本：v2.0 ｜ 日期：2026-11-14
> **v2.0 架构反转**：v1.0 以"Web 终端 + Gateway 数据面"为核心；v2.0 确认产品的根本核心是**服务端数据中枢**——服务器信息与密钥数据在服务端数据库中**唯一且统一管理**。终端界面只是客户端"用户壳"，后续可扩展 Windows/Linux 桌面、iOS、Web 浏览器端。
> 连接数据面由客户端**以其所在本地网络直连目标服务器**，中枢不做代理、不做 PTY、不做转发监听。
> v1.0 文档（`TermHub-产品设计与需求文档.md`）存档保留；其 §1.2、§2、§4 数据面相关、§7、§8 被本版取代，§6 数据模型与 Termius 调研结论继续有效。

---

## 1. 产品定位

### 1.1 一句话

**自托管的主机与凭据数据中枢 + 多端客户端：服务器信息与密钥在自有服务器的数据库中唯一统一管理，任何端同步后即可在本地网络直连目标服务器。**

### 1.2 与 Termius 的关系（v2.0 口径）

架构上与 Termius **同类**（云端 Vault 同步 + 客户端本地直连），差异在于云是自己的、客户端是自研的：

| 维度 | Termius | eterm |
|---|---|---|
| 数据源 | 官方云（别人的服务器，E2EE 零知识） | **自托管中枢（自己的服务器）**，服务端静态加密 |
| 同步 | 付费墙（Pro $120/年） | 天然属性，零边际成本 |
| SSH 数据面 | 客户端直连（"not a proxy"） | **客户端直连（相同）**，中枢不过流量 |
| 客户端 | 5 端原生 App | **Mac + Android（当前需求）**；Flutter 一套代码可扩展 iOS/Windows/Linux；Web 为后续可选弱端 |
| 凭据出口 | 云端只存密文 | 中枢加密落盘，TLS 下发，客户端 OS 钥匙串缓存 |
| 成本 | 订阅 | 自有机器 + 已有 MySQL 的边际成本 |

### 1.3 目标用户与成功标准

- **首要用户**：作者本人（1 人，管理数十至数百台主机，多设备访问）。
- **次要用户**：愿意自托管的小团队（≤10 人），后置。
- **成功标准（MVP）**：Mac 与 Android 两端从中枢同步同一份主机/密钥数据，各自在本地网络直连目标服务器完成日常 SSH 工作；**中枢离线时，两端仍可用已同步数据连接**。

---

## 2. 核心架构决策

### 2.1 决策一：同步面与数据面彻底分离

这是 v2.0 的第一原则，所有设计由此推导：

```
┌────────────────┐   同步面(TLS/REST+WS通知)   ┌─────────────────────┐
│ Mac 客户端      │◄──────────────────────────►│ 中枢服务 (Go)        │──► MySQL
│ Flutter + Rust  │   主机/密钥/配置 增量同步     │ 数据API / 同步 / 认证 │   (已有实例)
│  core           │                             │ /设备管理            │
└───────┬────────┘                             └─────────────────────┘
        │  数据面：SSH/SFTP 标准协议，客户端所在网络直连
        ▼
┌────────────────┐
│ 目标服务器      │
└────────────────┘

┌────────────────┐        （Android 同构：Flutter + 同一 Rust core）
│ Android 客户端  │──────────── 同步面同上；数据面同上 ────► 目标服务器
└────────────────┘
```

- **同步面**：客户端 ↔ 中枢。主机、组、密钥、Snippets、转发规则等配置数据的 CRUD 与增量同步。中枢是唯一事实源。
- **数据面**：客户端 → 目标服务器，标准 SSH/SFTP 协议直连。**中枢永远不出现在数据面上**（默认；可选应急中转见 §10 待定项）。
- 推论：客户端与目标同网时（家庭/办公内网），**中枢不在线也能连接**——离线可用性是 v1.0 Gateway 架构给不了的。

### 2.2 决策二：凭据安全模型（已拍板：服务端静态加密）

| 层 | 方案 |
|---|---|
| 中枢落盘 | 主密钥由环境变量注入（不落盘、不入库），敏感字段（`*_enc`）AES-256-GCM 加密存 MySQL。磁盘/备份被盗 ≠ 凭据泄露 |
| 传输 | 强制 TLS（Let's Encrypt）。部署形态为**公网 VPS（已拍板）**，安全基线见 §7 |
| 客户端本地 | 同步下来的数据以 OS 钥匙串加密缓存：macOS Keychain / Android Keystore。**本地库是离线 working set，可脱机连接** |
| 认证 | 用户名 + 口令（Argon2id）登录 → 签发**设备级长期 token**（存客户端钥匙串，服务端只存 hash）；Passkey/WebAuthn 后置（P1） |
| 设备管理 | 每台客户端注册为一个 Device，可查看最后活跃、随时吊销；吊销后该设备下次同步即失效 |
| 解锁概念 | **取消 v1.0 的"主口令解锁 Vault"**：中枢持主密钥，认证通过即数据可用。换取多端无口令摩擦，代价是信任边界=自己的服务器（与 v1.0 §2.1 的论证精神一致：自己的机器上做零知识收益近零成本极高） |

> ⚠️ 该模型的明确代价：中枢被入侵且攻击者可读取进程内存/env 时，凭据可被导出。接受此风险换取架构简单；若未来要求更高，数据模型已按密文字段设计，可平滑升级 E2EE（见 §10）。

### 2.3 决策三：客户端 = Flutter UI + Rust core（已拍板）

```
┌─────────────────────────────────────────────┐
│ Flutter UI（一套代码：Mac 桌面 + Android）     │
│   页面 / 状态管理 / 终端渲染 (xterm.dart)      │
├──────────── FFI（flutter_rust_bridge）───────┤
│ Rust core（全部业务核心，平台无关、可单测）     │
│   ├─ store  本地 SQLite + OS 钥匙串加密缓存    │
│   ├─ sync   同步引擎（cursor/重试/冲突处理）    │
│   ├─ ssh    russh：会话/跳板链/代理/端口转发    │
│   ├─ sftp   SFTP 客户端                       │
│   └─ keygen Ed25519/ECDSA/RSA 生成与导入导出   │
├─────────────────────────────────────────────┤
│ 平台层：macOS Keychain / Android Keystore /   │
│ JNI（Android 钥匙串）/ 平台通道（通知、保活）   │
└─────────────────────────────────────────────┘
```

- 疑似 Termius 同款路线（其 GitHub 有 `flutter_rust_bridge` fork），可行性已被验证。
- Rust core 与 UI 完全解耦：未来 iOS / Windows / Linux 客户端只是 Flutter UI 复用，甚至可出纯 CLI。
- 终端渲染用 **xterm.dart**；已知风险（Flutter 中文 IME）见 §9，M0 强制做 spike。

### 2.4 决策四：服务端 = Go + MySQL（已拍板）

- 单静态二进制，外部连接**用户已有 MySQL**（按 8.x / utf8mb4 / InnoDB 设计），`./eterm serve` 一条命令启动。
- 职责收窄为四块：**数据 API、同步、认证与设备管理、（预留）可选代理接口**。v1.0 的 PTY/SFTP 代理/转发监听/分帧协议全部作废。
- v1.0 选 Go 的 SSH 库理由随架构反转失效，但单二进制、部署简单、并发模型的理由都还在。

### 2.5 决策五：Web 壳定位为"后续可选弱端"

客户端直连架构下浏览器是天然弱端（无 TCP 能力）。后续 Web 端两条路线，均后置：
1. **WASM SSH**：Rust core 编译到 WASM，浏览器内实现 SSH 协议 + Direct Sockets API（仅 Chromium 且受限）。
2. **经中枢可选代理**：中枢提供 WS↔SSH 代理模块（默认关闭、显式开启）。
→ 结论：**服务端在架构上预留代理接口位，MVP 不实现**。Web 壳不进入当前任何里程碑。

---

## 3. 同步协议设计

单用户/小团队规模，设计目标：**离线优先、实现简单、冲突可控**。

### 3.1 基本机制

- 每实体携带 `rev`（全局单调递增版本号）与 `deleted_at`（软删标记）。
- 服务端维护 append-only 变更表 `changes(entity_type, entity_id, rev, ts)`，作为增量源。
- **拉取**：`GET /api/sync/pull?cursor=<rev>&types=a,b,c` → 返回 `(cursor, changes[])`，分页。
- **推送**：`POST /api/sync/push` 携带实体 + 客户端所见 `base_rev`（乐观锁）；版本不符返回 409。
- **实时性**：WebSocket 仅作通知（"有新变更"事件），客户端收到后自行 pull——不推数据本身，实现最简单且天然幂等。
- 客户端 sync 引擎：启动时全量对账（cursor 丢失时）→ 常态增量 pull/push → WS 通知触发即时 pull；指数退避重试。

### 3.2 冲突处理

- 单用户场景冲突罕见。策略：**字段级 LWW**（按 `updated_at`）+ 冲突写入审计表供查询。
- 密钥对象按**不可变版本化**处理：私钥内容一旦创建不覆盖，修改 = 新版本指向——从源头消灭密钥冲突。
- 删除为软删，同步语义统一为"收到 tombstone"。

### 3.3 凭据下发格式

TLS 内返回**解密后的可用数据**（服务端静态加密模型的直接推论）。客户端收到后立即以 OS 钥匙串加密落本地库，内存中持有。日志/缓存层禁止落凭据明文（客户端侧掩码规则同 v1.0 F10.3）。

---

## 4. 数据模型（v2 修订）

```
── 同步实体（客户端缓存 + 增量同步） ──────────────────────
Vault(id, name, scope[personal|team], owner_id, logging_enabled, created_at)
├── Group(id, vault_id, parent_id, label, settings_json, sort)
│   └── Host(id, group_id, vault_id, label, hostname, tags[], icon, notes, settings_json)
│       └── HostProtocol(id, host_id, kind[ssh|sftp|telnet|serial], config_json, sort)
├── Identity(id, vault_id, label, username, password_enc, key_id)
├── SshKey(id, vault_id, label, key_type, private_enc, cert_enc, passphrase_enc,
│          public_key, fingerprint, origin[generated|imported|fido2|biometric])
├── KnownHost(id, vault_id, hostname, key_type, key_enc, comment)
├── PortRule(id, vault_id, host_id, label, kind[local|remote|dynamic],
│            bind_addr, local_port, remote_host, remote_port, enabled)
├── Snippet(id, vault_id, package_id, description, script, target_host_ids[], vars_json)
└── SnippetPackage(id, vault_id, label)

── 中枢自有实体（不同步到客户端数据集） ──────────────────
User(id, username, pwd_hash, created_at, locked_until)
Device(id, user_id, name, platform, token_hash, created_at, last_seen_at, revoked_at)
SyncCursor ← changes(entity_type, entity_id, rev, ts)  [append-only]
AuditEvent(id, ts, actor_id, device_id, action, target_type, target_id, detail_json, ip)

── 各同步实体公共字段 ──────────────────────────────────
rev BIGINT, updated_at, deleted_at, created_at
```

设计要点：
- `settings_json` 键级 merge 继承（Termius 同款）沿用 v1.0。
- `*_enc` 字段由中枢主密钥加密；v2.0 中由**服务端**加解密（客户端收到明文语义数据），与 v1.0 的差异见 §2.2。
- v1.0 的 `SessionLog` 移出同步数据集：会话在客户端发生，日志默认**客户端本地记录**（Termius 模式：每 Host 留最近一条 + Bookmark 长期保留），可选上报中枢汇总（P2）。
- 大文本（会话日志、导入文件）一律不进 MySQL 主表。

---

## 5. 功能需求

执行位置标注：【中枢】= Go 服务端；【客户端】= Flutter/Rust。

### P0（MVP：不满足则产品不成立）

**F1 中枢基础**【中枢】
- F1.1 单二进制 + 已有 MySQL；环境变量注入主密钥与 DSN；首次启动 CLI 引导创建管理员。
- F1.2 认证：用户名 + 口令（Argon2id + pepper）→ 设备 token 签发；失败锁定。
- F1.3 设备管理 API：注册、列表、吊销（客户端设置页消费，无 Web 管理界面）。
- F1.4 同步 API：pull/push/changes 表（§3）。
- **验收**：空白机器 10 分钟内起服务并注册设备。

**F2 数据管理**【中枢 + 客户端 UI】
- F2.1 Host CRUD：label、hostname、port、tags、icon、备注；单 Host 多协议（SSH 必选，SFTP/Telnet 可选）。
- F2.2 Groups 可嵌套，组级设置（凭据、跳板链、代理、环境变量、启动命令、终端主题）键级继承，Host 显式覆盖。
- F2.3 Tags 多标签 AND 过滤 + 搜索；列表虚拟滚动（500+ 主机流畅）。
- **验收**：两端各自修改同一 Vault 数据，均能在秒级看到对方变更（WS 通知）。

**F3 SSH 终端（客户端核心壳）**【客户端】
- F3.1 Mac 客户端：登录 → 同步 → Host 列表 → xterm.dart 终端（russh PTY 流）；真彩色、鼠标上报、OSC 52 剪贴板、Bracketed Paste。
- F3.2 Android 客户端：同上 + 移动交互（方向键手势、双击 Tab、捏合字号、可重排键盘附加条）。
- F3.3 认证方式：口令 / 私钥 / 私钥+证书。
- F3.4 会话状态三色灯（🟢有输出 / 🟡等输入 / 🔴出错）与断线自动重连 + 本地回显缓冲重放。
- **验收**：**M0 spike 先行**——Flutter 中文 IME 输入正确、russh 长会话稳定（`top`/`tail -f` 30 分钟）、双端同一套 Rust core 编译通过。

**F4 Keychain**【客户端 + 中枢存储】
- F4.1 Key 对象（私钥+公钥+证书+passphrase）、Identity（用户名+口令+Key 组合），引用式管理，改一处全局生效。
- F4.2 Rust 生成 Ed25519 / ECDSA / RSA；导入 OpenSSH 格式文件/粘贴；**支持导出**（Termius 明确缺口）。
- F4.3 一键部署公钥到目标机 `authorized_keys`（客户端经自己的 SSH 连接执行，可指定路径/文件名，成功后自动关联）。
- F4.4 Known Hosts 管理与首次连接指纹确认。
- **验收**：Mac 上生成 Ed25519 → 部署到目标机 → Android 同步到该 Key → 手机直连免密。

### P1（对齐 Termius 日常体验；对齐后可停订）

**F5 连接进阶**【客户端】：跳板链（多级）、SOCKS5/HTTP 代理、Agent Forwarding（客户端内置 agent）、环境变量下发（SendEnv 语义 + 服务端 AcceptEnv 提示）、Startup Command。
**F6 SFTP**【客户端】：双面板（本地 = 设备文件系统 / 远端）、拖拽、断点续传、传输队列与冲突处理、远端文件编辑回传。
**F7 端口转发**【客户端】：Local/Remote/Dynamic 规则化、双击启停、客户端本地开监听（桌面可绑指定地址；Android 绑 loopback 供本机 App 使用）、端口占用预检。
**F8 Snippets**【客户端 + 中枢同步】：描述+脚本、Package 组织、四种执行入口（Paste/Run/Autocomplete/批量）、**变量支持**（`{{host.label}}`、`{{input:name}}`、`{{select:a,b}}`、`{{env.X}}`——补 Termius 缺口）、多主机批量执行。
**F9 导入导出**【中枢 API + 客户端 UI】：导入 `~/.ssh/config`（ProxyCommand 忽略并告知、JumpHost 转跳板链）、CSV；导出全量 JSON/YAML + `ssh_config`（反向可被 `ssh -F` 使用）。提供 CSV 模板（Termius 无官方导出，迁移第一摩擦）。
**F10 会话日志**【客户端本地】：每 Host 留最近一条 + Bookmark；敏感掩码规则（口令提示不记录、正则脱敏）；导出单条日志；可选上报中枢（P2 再做上报）。
**F11 Passkey/WebAuthn 登录**【中枢】：作为口令之外的登录方式。
**F12 Autocomplete 与 Shell Integration**【客户端】
- F12.1 补全数据源：命令历史（客户端本地库；随 Vault 同步为 P2 可选）、远端文件/目录路径（依赖 Shell Integration）、Snippet 名与内容、检测到口令提示时建议对应 Identity（sudo 场景）。
- F12.2 Shell Integration 三态：`auto`（默认）/ `on` / `off`，Host/Group 级可配；`auto` 首次连接经**独立短连接**探测（不污染主会话），失败自动降级 `off` 并提示一次。
- F12.3 降级损失仅限：工作目录显示、路径/历史补全、Workspaces 的目录恢复；终端本身完全可用。
- F12.4 兼容性设计沿用 v1.0 §2.5 的教训：额外 exec 通道可能被收紧的 sshd 拒绝并直接断连（服务端需 `MaxSessions ≥ 2`）；三态 + 自动降级即为应对，探测失败不得影响主会话。

### P2（差异化增值，默认关闭）

**F13 Workspaces**【客户端·桌面】：布局/连接/工作目录/运行命令快照模板；分屏 ≤16 + 广播输入。
**F14 iOS 客户端**【客户端】：Flutter 代码库直接出 iOS，Rust core 复用。
**F15 Web 壳**【中枢预留 + 客户端 WASM 路线评估】：见 §2.5，需先立项评审。
**F16 AI（BYOK）**【客户端】：自带 Key、三个入口（命令生成/Snippet 生成/选区上下文）、**默认不发送任何终端内容**、发送前可编辑预览、应用 F10 掩码。
**F17 审计**【中枢】：登录/设备变更/凭据查看导出/部署公钥等管理操作审计（append-only）；数据面连接行为由客户端上报（可选）。
**F18 团队共享 Vault**：Editor/Viewer 两档、Snippet 跨 Vault 分享。
**F19 FIDO2 / 生物识别密钥**：`sk-*` 由客户端在硬件上生成（直连架构下天然正确：YubiKey 插在 Mac/手机上）；SEP/TPM 生物识别密钥走平台通道。

---

## 6. 里程碑

| 阶段 | 周期 | 内容 | 出口标准 |
|---|---|---|---|
| **M0 骨架** | 2~3 周 | **spike 三项：Flutter 中文 IME、russh 长会话、flutter_rust_bridge 双端编译**；中枢（认证+设备+数据 API+同步+**公网安全基线**）；Mac 客户端骨架（登录/同步/列表/终端） | 公网 VPS 上按 §7 基线上线；Mac 上同步主机列表并直连一台服务器跑命令；**停掉中枢进程，Mac 仍可连接** |
| **M1 双端** | 2 周 | Android 客户端（含移动键盘条/手势）；Keychain 全量（生成/导入/导出/部署公钥/Identity） | 同一份数据两端无缝使用；手机免密直连 |
| **M2 对齐** | 2~3 周 | 跳板链/代理、SFTP 双面板、端口转发、Group 继承/Tags 完整化 | 逐项核对 Termius 功能清单（用调研报告 §九反向验证），**此时可停订 Termius** |
| **M3 迁移** | 2 周 | 导入导出（ssh_config/CSV）、Snippets+变量、会话日志、环境变量、Autocomplete（三态降级）、Passkey | 从 Termius 手工 CSV 迁入真实数据完成切换 |
| **M4 增值** | 持续 | Workspaces/分屏广播、iOS、AI BYOK、审计、团队 Vault、FIDO2 | 按需启用 |

**最大不确定性前移到 M0**：三个 spike 任一失败即触发技术栈复议（IME 失败 → 评估平台原生终端组件或 Tauri 路线），避免中后期返工。

---

## 7. 部署与安全基线

| 项 | 方案 |
|---|---|
| 部署形态 | **公网 VPS（已拍板，M0 起即公网）**。安全基线全部进入 M0：失败锁定 + IP 白名单 + 反代 TLS + 最小端口暴露 |
| TLS 证书 | Let's Encrypt（Caddy 反代自动签发，或 Go autocert 内嵌二进制）；客户端按正常 CA 信任链校验，无需特殊配置 |
| MySQL | 用户已有实例；utf8mb4 / InnoDB；**仅监听本机/内网，绝不对公网暴露**；备份 = mysqldump 定时 + 主密钥与 DB 分开保管 |
| 中枢无状态化 | 除 MySQL 外无本地状态（日志外发 stdout），可随时重建容器/进程 |
| 客户端失窃 | 设备吊销即断同步；本地缓存由 OS 钥匙串加密；远期可选"下次上线强制擦除"指令 |

---

## 8. 明确不做（v2.0 修订）

| 不做 | 理由 |
|---|---|
| **中枢出现在数据面**（代理/PTY/转发监听，默认） | v2.0 第一原则反转；仅保留 §2.5 的架构预留位 |
| Mosh | 原生客户端其实具备可行性，但 Rust 无成熟 Mosh 栈；继续用 KeepAlive + 重连缓冲，P2 再评估 |
| RDP / VNC | 与终端定位无关 |
| 多租户 / 商业计费 / SAML / SCIM | 单人自用 |
| Electron 客户端 | 已被 Flutter+Rust 取代（v1.0 反对 Electron 的理由继续成立） |
| 浏览器侧 E2EE | 架构已反转，见 §2.2 |
| 中枢 Web 管理界面 | 设备管理在客户端设置页完成；避免多一套前端 |
| 原生 iOS 独立开发 | Flutter 一套代码直接出 |

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **Flutter 终端中文/IME 输入缺陷** | 高 | M0 首项 spike；xterm.dart 不达标则换自绘或平台方案，M0 内定案 |
| russh 覆盖面（证书认证/agent forwarding/多跳） | 中 | M0 长会话 spike 一并验证；个别能力降级用系统 `ssh` 进程兜底（桌面端） |
| Android 后台连接被杀 | 中 | 前台服务 + 通知；语义同 Termius（20~30s 级），不虚构保活能力 |
| 客户端 token / 本地库泄露 | 高 | 钥匙串加密 + token 可吊销 + 客户端日志禁落凭据（含 AWS key 正则掩码回归） |
| **中枢公网暴露遭爆破/扫描** | 高 | M0 安全基线兜底：Argon2id + 失败锁定 + IP 白名单 + 反代 TLS + 最小端口暴露；设备 token 高熵且服务端只存 hash；MySQL 不对公网监听 |
| 同步冲突 / 数据丢失 | 中 | 乐观锁 + 软删 + 密钥不可变版本化 + changes 表可追溯 |
| MySQL 单点 | 中 | 用户已有实例的既有备份体系 + `*_enc` 字段使备份泄露不等于凭据泄露 |
| 范围膨胀 | 高 | M2 停订验收后冻结新功能；新壳（iOS/Web）只在 Rust core 无需大改时排期 |

---

## 10. 决策记录

已拍板（2026-11-14）：
1. 产品核心 = 服务端数据中枢；终端为可替换客户端壳。
2. 数据面客户端本地直连，中枢不做代理；**应急中转亦不做**，仅预留接口位。
3. 加密模型 = 服务端静态加密 + TLS + 客户端 OS 钥匙串缓存。
4. 客户端 = Flutter + Rust core（Mac + Android 先行）。
5. 服务端 = Go + **MySQL**（复用已有实例，替代 v1.0 的 SQLite）。
6. 项目代号 = **eterm**。
7. 部署 = **公网 VPS**，M0 起即按 §7 安全基线上线。
8. Passkey = **P1**，M0 用口令 + 设备 token 先行。

待定：无——v2.0 全部决策已确认。
