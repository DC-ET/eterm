# Web 终端系统 · 产品设计与需求文档

> 项目代号：**TermHub**（可改）
> 版本：v1.0 ｜ 日期：2026-09-20
> 撰写背景：原 Termius Pro 重度用户，因订阅成本与功能契合度转向自建。
> 本文档范围：**产品定位、架构决策、数据模型、功能需求（分优先级）、非功能需求、技术选型、里程碑、明确不做的事、风险**。
> 术语说明：`Gateway` = 运行在你服务器上的常驻服务；`Web 控制台` = 浏览器端界面；`Vault` = 加密凭据库（沿用 Termius 概念，降低迁移认知成本）。

---

## 1. 产品定位

### 1.1 一句话

**部署在自己服务器上的多协议终端中枢，浏览器即客户端，数据与凭据自持，无订阅、无云账号。**

### 1.2 与 Termius 的关系定位

不是"开源版 Termius"，而是**架构换轨后的同类产品**。Termius 的护城河是"跨 5 端同步"，TermHub 的立身之本是"数据本来就在你的服务器上"——同步因此变成零成本属性而非增值项。

| 维度 | Termius | TermHub（本设计） |
|---|---|---|
| 运行位置 | 客户端本地，云端只存加密 Vault | **Gateway 常驻你的服务器**，是唯一权威数据源 |
| 入口 | 5 个原生 App | Web（PWA）为主；CLI/`~/.ssh/config` 导出为辅助 |
| 同步 | 付费墙（Pro 才有） | 天然即同步，无此概念 |
| SSH 流量 | 直连，不经官方（"not a proxy"） | 经自己的 Gateway（网关即你的资产） |
| 凭据 | 静态加密 + 端到端，云端不可读 | Gateway 持有，DB 静态加密；信任边界是自己的机器 |
| 成本 | Pro $120/年/席 | 自有机器的边际成本 |

### 1.3 目标用户与成功标准

- **首要用户**：作者本人（1 人，管理数十至数百台主机，多设备访问）。
- **次要用户**：有同类痛点、愿意自托管的小团队（≤10 人）。
- **成功标准（MVP）**：作者停掉 Termius 订阅后，日常 SSH/SFTP/跳板/端口转发/会话记录工作 100% 迁移到 TermHub，无功能回退。

---

## 2. 核心架构决策

这一节是全文最重要的部分——后续所有功能取舍都由这里推导。

### 2.1 决策一：Gateway 持有凭据，不做浏览器端 E2EE

**结论：Gateway 侧加密静态存储 + 主口令解锁，浏览器与 Gateway 之间只走 TLS。不做"浏览器侧派生密钥、云端零知识"那一套。**

理由（与 Termius 的区别必须讲清楚）：
- Termius 做 E2EE 是因为数据在**别人的服务器**上，零知识是它的信任基础。
- TermHub 的 Gateway 跑在**用户自己的机器**上。攻击者若已能读取该机器的进程内存，E2EE 不提供额外保护（解锁后凭据必然在内存中明文）。
- 因此 E2EE 在此场景**收益接近于零，成本极高**（密钥托管、恢复流程、共享、导入导出全被复杂化）。

**采纳的安全等价物**：DB 静态加密（Argon2id 派生主密钥加密敏感字段），使"磁盘/备份被盗"不等于"凭据泄露"。未解锁时 Gateway 无法对外提供凭据相关操作。

### 2.2 决策二：所有网络能力前移，抑制 Web 沙箱限制

Termius 的功能集里有一批在浏览器里拿不到权限的能力。Gateway 架构把它们全部变成"服务端能力"，**这是本设计相对 Termius Web 版的根本优势**：

| 能力 | 浏览器原生方案 | TermHub 方案 | 收益 |
|---|---|---|---|
| 本地终端 | ❌ 不可能 | ✅ Gateway 的 shell | 直接可用 |
| Serial 串口 | Web Serial API，仅 Chromium | ✅ Gateway 所在机器插 USB 转串口线即可 | **比 Termius 更强**（Termius 需 Redpark 专用线且仅本机） |
| 端口转发 | ❌ 浏览器无法开监听 | ✅ Gateway 上开监听，可绑定 `127.0.0.1` / `0.0.0.0` / `tailscale0` | 见 2.3 |
| Mosh | ❌ 无 UDP | ⚠️ 放弃，用保活 + 断线缓冲替代 | 明确砍掉（见 §9） |
| SFTP | File System Access API 残缺 | ✅ Gateway 代理，双面板完整 | 完整可用 |
| 生物识别密钥 | WebAuthn ✅（但仅认证用途） | Gateway 侧 + WebAuthn 登录 | 登录侧反而比 Termius 更原生 |

**关键洞见**：既然 Gateway 在服务器上，"访问防火墙后的服务"这件事反而更好办了——转发端口开在 Gateway 上，同 VPN/同内网的任何设备（包括手机）都能直接 `curl gateway_ip:3336`，不需要 Termius 那种"必须有一台开着 Termius 的机器"。

### 2.3 决策三：部署形态先定，功能后定

这是本产品最大的实际风险点，**必须在架构期决定**。提供三档，默认第二档：

| 模式 | 暴露面 | 认证要求 | 适用 |
|---|---|---|---|
| A. 仅本机 | `127.0.0.1` | 无（靠 SSH 隧道保护） | 最高安全，配 `ssh -L` 使用 |
| B. 内网/VPN（**默认**） | Tailscale / WireGuard / 内网 IP | WebAuthn + 主口令 | **推荐**，兼顾便利与安全 |
| C. 公网 | 域名 + 反代 | WebAuthn + 主口令 + 速率限制 + IP 白名单 + 2FA | 需要随时外访时 |

默认 B；C 需显式开启并在首次启动时强提示风险。任何模式都强制 HTTPS/TLS（B 用 Tailscale 自带 magicDNS 证书，C 用 Let's Encrypt）。

### 2.4 决策四：终端数据面与控制面分离

- **控制面**：REST/JSON（主机 CRUD、凭据、配置）。
- **数据面**：每个会话一条独立 WebSocket，二进制分帧，开销最小。
- 分帧格式（自定义，极简）：
  ```
  [1B type][4B length][payload]
  type: 0=stdout  1=stdin  2=resize  3=signal  4=exit
        5=sftp-op  6=notice  7=port-fw  8=broadcast-enable
  ```
- 理由：不要复用 HTTP/SSE 传终端字节流，会在高吞吐下（`tail -f`、`top`）成为瓶颈。

### 2.5 决策五：Shell Integration 可选且可降级

Termius 的教训：为取路径/历史额外开 `exec` 通道，会**被收紧的 sshd 拒绝并直接断连**（官方要求 `MaxSessions ≥ 2`）。

TermHub 设计：
- 每个 Host 有 `shell_integration` 三态：`auto`（默认）/ `on` / `off`。
- `auto` 模式首次连接时探测，失败即自动降级为 `off` 并提示用户一次。
- 降级后功能损失仅限：工作目录显示、路径/历史补全、workspace 模板的目录恢复。**终端本身完全可用**。
- 探测使用独立短连接，不污染主会话。

---

## 3. 功能需求 · P0（MVP，不满足则产品不成立）

### F1 账户与认证
- **F1.1** WebAuthn/Passkey 登录为主，口令为兜底（明文口令哈希 Argon2id + pepper）。
- **F1.2** 主口令解锁 Vault（会话级，内存持有，可设置自动锁定超时，默认 30 分钟无操作）。
- **F1.3** 启动时检测公网暴露：非回环地址监听 + 未配置 WebAuthn → 拒绝启动并提示。
- **验收**：新部署 5 分钟内完成注册 → 登录 → 解锁；无 WebAuthn 时口令路径可用。

### F2 Host 管理
- **F2.1** Host CRUD：label、hostname、port、tags、icon、备注。
- **F2.2** 单 Host 多协议：SSH / SFTP / Telnet（各自独立端口与凭据）。SSH 必选，其余可选。
- **F2.3** Groups：可嵌套；组级设置（协议、凭据、跳板链、代理、环境变量、启动命令、终端主题）被子 Host **逐参数继承**，Host 可显式覆盖。
- **F2.4** Tags：多标签 AND 过滤 + 搜索。
- **F2.5** Host 列表虚拟滚动，500+ 主机下滚动帧率 ≥ 50fps。
- **验收**：配置一个"生产"组设置红色主题 + 跳板链，组内 10 台主机自动继承；单独覆盖其中 1 台的端口，其余不受影响。

### F3 SSH 终端
- **F3.1** 基于 xterm.js + Gateway PTY 的完整终端；支持真彩色、鼠标上报、剪贴板（OSC 52）、Bracketed Paste。
- **F3.2** 认证方式：口令 / 私钥 / 私钥+证书 / Agent Forwarding。
- **F3.3** 跳板链（多级）、SOCKS5/HTTP 代理。
- **F3.4** 分屏（≤ 16 路）与广播输入；快捷键可自定义。
- **F3.5** 会话状态指示：有新输出 / 等待输入 / 已断开（三态灯，沿用 Termius 验证过的设计）。
- **F3.6** 断线自动重连，重连后本地回显缓冲重放；不承诺"服务端会话保活"（依赖远端 tmux，产品内不实现）。
- **验收**：连一台需二次跳板的机器一键可达；分屏 8 路同时跑 `top`，CPU 占用可接受；杀掉网络 10 秒后恢复，之前输出仍可见。

### F4 SFTP
- **F4.1** 双面板（本地 / 远端），本地侧为 Gateway 能访问的文件系统。
- **F4.2** 拖拽传输（面板间 + 从浏览器拖入）、右键上传下载、断点续传。
- **F4.3** 远端文件编辑：下载→本地编辑→变更检测→提示回传（Termius 模式）；保留"终端内 vim 直接改"路径。
- **F4.4** 传输队列面板：进度、冲突处理（替换/保留两者）、失败可重试。
- **验收**：拖一个 100MB 文件到远端，进度可见、取消可中断；编辑 `nginx.conf` 后回传成功。

### F5 Keychain
- **F5.1** Key 对象：私钥 + 公钥 + 证书 + passphrase，统一容器；被 Host/Identity 引用。
- **F5.2** 生成 Ed25519 / ECDSA / RSA；导入文件或粘贴；**必须支持导出**（这是 Termius 的明确缺口）。
- **F5.3** Identity：用户名 + 口令 + Key 的组合，多处引用；改一处全局生效。
- **F5.4** 一键部署公钥到 Host 的 `authorized_keys`（可指定自定义路径与文件名），成功后自动关联。
- **F5.5** Known Hosts 管理与指纹确认。
- **验收**：生成 Ed25519 → 一键部署到 3 台机器 → 后续一键连接，无口令提示。

---

## 4. 功能需求 · P1（对齐 Termius 既有体验）

### F6 数据导入导出（**最高优先级，先于新功能**）
- **F6.1** 导入：`~/.ssh/config`（含 known_hosts 与密钥文件）、CSV、PuTTY（`.reg`）、MobaXterm（`.ini`）、SecureCRT（`.xml`）。
- **F6.2** `~/.ssh/config` 导入限制：`ProxyCommand` 忽略并列出清单告知用户，`JumpHost` 转为跳板链。
- **F6.3** 导出：全量 **JSON/YAML**（含凭据，需主口令二次确认）+ **`ssh_config`**（供命令行客户端复用）。
- **F6.4** ⚠️ **Termius 无官方导出能力**，用户现有数据迁移需先手工整理为 CSV 或从本地 Termius 数据目录提取。此为本项目的第一道迁移摩擦，须在文档与 UI 中明确告知，并提供 CSV 模板。
- **验收**：从 Termius 手工导出的 CSV 导入后 Group/Tag/凭据完整；反向导出 `ssh_config` 能被 `ssh -F` 直接使用。

### F7 端口转发
- **F7.1** Local / Remote / Dynamic 三类，规则可命名、可保存，双击启停。
- **F7.2** **绑定地址可配置**：`127.0.0.1` / `0.0.0.0` / 指定网卡（如 `tailscale0`）。默认仅回环，公网模式默认仍回环并强提示。
- **F7.3** 活跃规则集中视图 + 冲突检测（端口占用预检）。
- **F7.4** P2：WebSocket↔TCP 桥，使浏览器内应用也能使用转发隧道。
- **验收**：设一条 local 转发指向内网数据库，在 Gateway 上 `psql -h 127.0.0.1 -p 3336` 连通；绑定 `tailscale0` 后手机可连通。

### F8 Snippets
- **F8.1** 描述 + 脚本两字段；Snippet Package 文件夹式组织。
- **F8.2** 四种执行入口：侧栏 Paste / Run、Autocomplete、多主机批量执行、Startup Command。
- **F8.3** 多主机批量：一为"新建连接并自动组 workspace"（可保存目标集），一为"在当前已开的所有终端执行"。
- **F8.4** **变量支持**（Termius 明确不支持，本项目补齐）：`{{host.label}}`、`{{host.name}}`、`{{input:name}}` 交互式占位、`{{select:a,b,c}}` 枚举，执行前弹出参数表单。
- **验收**：写 `systemctl restart {{select:nginx,gunicorn}}`，在 5 台机器上分别选对服务执行，一次完成。

### F9 环境变量
- **F9.1** Host 与 Group 级 `KEY=VALUE`，连接时下发（等价 `SendEnv`）。
- **F9.2** 文档内提醒服务端需 `AcceptEnv` 放行，并提供一键生成推荐 `sshd_config` 片段的功能。
- **F9.3** 在 Snippet 变量体系中作为全局上下文可引用（`{{env.APP_ENV}}`）。

### F10 会话日志
- **F10.1** 记录 SSH / Serial / Telnet / 本地终端；默认每 Host 仅留最近一条，Bookmark 可长期保留并加备注。
- **F10.2** 按 Vault 过滤、按时间/书签排序、全文搜索。
- **F10.3** **敏感信息掩码**：检测到口令提示（不回显）时不记录；提供正则脱敏规则列表（默认含 `password=`、`token`、`AKIA[0-9A-Z]{16}` 等）。
- **F10.4** **支持导出单条日志**（修正 Termius 不可导出的缺陷）+ 可配置保留策略（条数/天数）。
- **F10.5** 移动端可查看日志（Termius 移动端仅记录不能看，本项目 Web 端天然一致）。
- **验收**：一次含 sudo 的会话日志中不见任何明文口令；导出的日志文件可直接归档。

---

## 5. 功能需求 · P2（差异化增值）

### F11 部署与运维
- **F11.1** 单静态二进制 + SQLite，`./termhub serve` 一条命令起服务；Docker Compose 备选。
- **F11.2** 配置以文件 + 环境变量 + CLI 三级覆盖；敏感项只走环境变量或交互输入，不落盘。
- **F11.3** 备份 = 拷贝 SQLite 文件（WAL 模式，支持在线热备）+ `termhub backup` 加密导出。
- **F11.4** 健康检查端点、Prometheus metrics（会话数、活跃转发、登录失败计数）。

### F12 移动端
- **F12.1** PWA：可安装、离线外壳、触摸手势（方向键/ Tab / 缩放）、键盘附加条（可重排自定义）。
- **F12.2** 响应式布局，手机端分屏退化为标签切换。
- **F12.3** 不做原生 App（除非出现明确需求），避免商店分成与审核成本。

### F13 AI 能力（BYOK，克制实现）
- **F13.1** 自带 API Key（加密存储），支持 OpenAI 兼容协议；不内置任何默认模型。
- **F13.2** 三个入口：终端内命令生成、Snippet 生成、终端选区作为附加上下文。
- **F13.3** **安全红线**：默认不自动发送任何终端内容；每次发送前展示将发送的文本并可编辑；应用 F10.3 的脱敏规则；提供"本会话禁用 AI"开关。
- **F13.4** 无 Key 时功能完全隐藏，不做任何推销式引导。

### F14 协作与分享（单人之后）
- **F14.1** 会话共享（只读 / 单人输入控制），WebSocket 房间实现，天然比原生端简单。
- **F14.2** Vault 级分享（Editor / Viewer 两档）。
- **F14.3** SSH ID 式公钥页：`/$/<handle>` 公开只读公钥 + 用户 CA 证书，一条 `curl` 写入 `authorized_keys`；可用 `ssh-keygen` 三步校验签发链。

### F15 审计（Termius 缺的一层）
- **F15.1** 独立于会话日志的**管理操作审计**：登录/登出、解锁失败、密钥查看与导出、`authorized_keys` 部署、转发规则启停、Vault 权限变更。
- **F15.2** 不可篡改（append-only 表 + 可选外发 syslog）。

---

## 6. 数据模型

```
Vault(id, name, scope[local|personal|team], owner_id, logging_enabled, created_at)
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
├── SnippetPackage(id, vault_id, label)
└── SessionLog(id, vault_id, host_id, owner_id, started_at, ended_at,
               bookmarked, comment, data_path, size_bytes)

User(id, username, pwd_hash, created_at, locked_until)
WebAuthnCred(id, user_id, credential_id, public_key, sign_count, transports[], name, created_at)
AuditEvent(id, ts, actor_id, action, target_type, target_id, detail_json, ip)
```

设计要点：
- `settings_json` 以**键级 merge**实现继承（Termius 同款），不做整块覆盖——保证"改组内一个参数不影响其他参数"。
- 所有 `*_enc` 字段由主密钥加密；主密钥只存在于内存，不落库。
- `SessionLog.data_path` 指向 Gateway 本地文件（大文本不入库），库内只存元数据，避免 SQLite 膨胀。

---

## 7. 技术选型

| 层 | 选择 | 理由 |
|---|---|---|
| Gateway | **Go** | 单静态二进制；`golang.org/x/crypto/ssh` 成熟；`github.com/pkg/sftp`；`creack/pty`；`modernc.org/sqlite` 纯 Go 驱动免 cgo，一个文件走天下 |
| Web | **Vue 3 + Pinia**（React 亦可，按你熟悉度） | 状态中枢需求清晰（主机/会话/转发/日志四块），Pinia 分 store 直观 |
| 终端 | **xterm.js** + 自研 WebGL/Canvas 渲染开关 | 生态标准，Termius 桌面端亦基于其衍生 |
| 存储 | **SQLite (WAL)**，预留 Postgres 迁移路径 | 单机单人无需额外服务；备份即拷文件 |
| 鉴权 | **go-webauthn** | Passkey 是浏览器原生能力，比口令体验与安全性都更好 |
| 部署 | 单二进制 / Docker Compose / systemd | 三选一，覆盖全部场景 |

明确不使用：Electron（Termius 的内存与体积问题正是反面教材）、任何需要在浏览器外安装运行时的 Web 方案。

---

## 8. 里程碑与验收

| 阶段 | 周期 | 内容 | 出口标准 |
|---|---|---|---|
| **M0 骨架** | 1 周 | 部署三档、WebAuthn+口令登录、主口令解锁、Host CRUD、首个 SSH 终端 | 空白机器上 10 分钟跑到"浏览器里连上一台服务器" |
| **M1 可用** | 2 周 | SFTP 双面板、Keychain、密钥生成与一键部署、Group 继承、Tags | 日常 SSH + SFTP 场景可脱离 Termius |
| **M2 对齐** | 2~3 周 | 导入导出（含 `ssh_config`）、端口转发、会话日志、Snippets、环境变量、跳板链 | 完成 Termius 现有功能 100% 覆盖核对 |
| **M3 体验** | 2 周 | 分屏广播、Workspaces 模板、PWA、主题、快捷键自定义 | 手机 PWA 上完成一次应急运维 |
| **M4 增值** | 持续 | AI BYOK、会话共享、SSH ID 式公钥页、审计、metrics | 按需启用，默认关闭 |

**M2 结束时即可停订 Termius**——这是本项目的关键收口点，建议在 M2 结束时做一次逐项功能核对（用 §10 的差距清单反向验证）。

---

## 9. 明确不做（砍掉范围）

比"做什么"更重要的是这些，每条都有明确理由：

| 不做 | 理由 |
|---|---|
| **Mosh** | 依赖 UDP + 本地预测回显语义，浏览器/中继场景下语义被破坏。以 SSH KeepAlive + 断线缓冲替代，移动端辅以 tmux |
| **RDP / VNC** | 与终端定位无关，Guacamole 已覆盖，不要摊薄焦点 |
| **多租户 / 商业计费** | 目标是自己用，不为假设的客户增加复杂度 |
| **SAML / SCIM** | 单人场景无意义 |
| **原生移动 App** | PWA 足够且零分成零审核；有需求再评估 |
| **"服务端会话保活"** | 依赖远端 tmux；产品内只做连接层韧性，不虚构能力 |
| **内置 AI 模型与自动上传** | 只做 BYOK + 显式确认，绝不默认发送终端内容 |
| **强制公网部署** | 默认内网/VPN，公网需显式开启并承担后果 |
| **浏览器侧 E2EE** | 见 §2.1，收益近零成本极高 |

---

## 10. 迁移与差距清单（必须直面）

从 Termius 迁出时的**已知损失与补偿**：

| Termius 能力 | TermHub 状况 | 补偿 |
|---|---|---|
| 官方导出 | ❌ 无 | 本项目自带全量导出；迁移时用手工 CSV 或本地数据目录提取（一次性成本） |
| iOS/Android 原生 App | PWA（体验略逊） | 安装后基本无感；应急场景足够 |
| Mosh | ❌ 不做 | KeepAlive + 重连缓冲 |
| Serial（Redpark 线） | Gateway 插 USB 转串口线 | **能力增强**，任意设备可用 |
| 团队共享 Vault | P2 实现 | 单人期不需要 |
| 硬件 FIDO2 密钥登录 SSH | Gateway 侧生成与使用 | 保留（`sk-*` 由 Gateway 生成并存储） |

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **公网暴露遭爆破** | 高 | 默认内网；公网强制 WebAuthn + 失败锁定 + IP 白名单 + 启动时探测非回环监听并告警 |
| **Gateway 单点** | 中 | 数据=SQLite+日志目录，一条命令备份；Gateway 本身无状态到可随时迁移 |
| **SQLite 写并发** | 中 | WAL + 单写者；日志大文本外置文件 |
| **终端高吞吐卡顿** | 中 | 独立 WS + 二进制分帧 + 背压（缓冲上限与丢帧策略），提供渲染模式切换 |
| **sshd 拒绝 exec 通道** | 中 | §2.5 的三态 + 自动降级 |
| **凭据误入日志** | 高 | F10.3 掩码 + 口令提示检测 + 上线前用含 sudo/AWS key 的真实会话回归 |
| **范围膨胀** | 高 | M2 之后冻结新功能，只做 §9 内事项；用 §8 的核对清单收口 |

---

## 12. 待你确认的决策点

以下我按默认口径设计，若与你预期不符请在开发前修正：

1. **技术栈**：默认 Go + Vue3。若你更熟 Node/TS，可整体换 Node（`ssh2` + `node-pty` + SQLite），代价是部署从单二进制变为 Node 运行时。
2. **用户规模**：默认**单人 + 可选注册开关**。若一开始就要多人，需前移 F14 并引入邮箱/邀请与权限模型。
3. **部署位置**：默认内网/VPN。若你只有一台公网 VPS，模式 C 的安全加固项需在 M0 就做掉。
4. **凭据加密粒度**：默认 DB 静态加密 + 内存主密钥。若你要求"磁盘被盗也不可读"，已有；若你还要求"进程被 dump 也不可读"，需引入浏览器侧 E2EE，会显著抬高 F6/F8/F14 的实现成本。
5. **项目代号**：TermHub 可换。
