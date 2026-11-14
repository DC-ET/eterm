# Termius 产品功能调研报告

> 调研日期：2026-09-20 ｜ 当前主版本：桌面端 10.1.0
> **本文只讨论产品功能**，不涉及公司背景、定价、商业争议与安全合规（这些见《Termius-调研报告.md》）。
> 主要信息来源：docs.termius.com 官方文档（LLM 友好的 Markdown 版，逐页通读）、termius.com/changelog 官方更新日志。
> 所有功能描述以官方文档为准；标注 ⚠️ 的是文档明确写出的限制或已知缺陷。

---

## 一、核心数据模型：Vault → Group → Host

Termius 与传统 SSH 客户端的根本分野：**不管理连接字符串，管理"机器 + 协议集 + 凭据引用"**。

```
Vault（顶层，访问控制 + 端到端加密存储单元）
└── Group（可嵌套，协议/凭据/跳板/主题等设置的继承单元）
    └── Host（一台主机 = 一个地址 + 多个协议配置）
        ├── SSH :22 (key: prod-key)
        ├── SFTP :22 (key: prod-key)
        ├── Telnet :23 (user: admin)
        ├── Mosh、Serial
        └── Jump host / Proxy / Agent Forwarding / 环境变量 / Startup Command
```

三个关键的"反直觉"设计（都是官方原文口径）：

1. **Vault 是一等公民，不只是容器。** Vault 存 Host、Group、Key、Snippet、Port Forwarding 规则、Known Hosts 六类对象，且**是访问控制与开关的最小单位**——会话日志的开关、按 vault 过滤日志、数据迁移都基于它。四级 Vault：`Local`（仅本机、不同步、不备份）、`Personal`（注册即建，仅自己）、`Team`（邀请首个成员时自动创建）、`Custom Team Vault`（细粒度权限）。
2. **Group 不是文件夹。** 官方专门用 hint 强调："Groups are not folders. On the Hosts screen, you see all hosts in the current groups and their subgroups." 所以把主机移出组后它仍可能出现在列表里。这是极易踩坑的点。
3. **Host 与协议解耦。** 一台机器配置一次，可同时拥有 SSH/SFTP/Mosh/Telnet 四种方式，各有独立端口与凭据。
   > **注意**：`Telnet` 在新版文档中是 Host 内部的可添加协议（Host details → `+ Add Telnet`），只有 `Serial` 是从 Hosts 屏幕单独发起的独立连接。

### Keychain：凭据的引用式管理

Keychain 是 Vault 内的凭据库，四类对象：

| 对象 | 内容 | 作用 |
|---|---|---|
| **Key** | 私钥 + 公钥 + 证书 + passphrase 的标签化容器 | 可被多个 Keychain item 与 Host/Group 引用 |
| **Identity** | 用户名 + 密码 + Key 的组合 | 消灭凭据重复；**检测到密码提示时 Autocomplete 会主动建议相应 identity**（sudo 场景） |
| **Certificate** | SSH 证书，与私钥绑定存储 | 二者缺一不可，故 Termius 把证书作为 Key 的一部分存 |
| **Known Hosts** | 远端公钥 | 连接时验证主机身份，防中间人 |

> 引用式管理是 Keychain 的精髓：密码改了只改 Keychain 一处，所有引用它的 Host 自动生效。多 Vault 场景下若列表里看不到 identity，是因为 identity 与 host 不在同一个 Vault——需在 Credentials 区的 `Credentials from` 里选对 Vault。

---

## 二、连接能力

### 2.1 协议矩阵

| 协议 | 支持情况 | 细节 |
|---|---|---|
| SSH | ✅ 密码 / Key / Certificate / FIDO2 / Biometric | 核心 |
| SFTP | ✅ 全 5 平台 | 双面板、拖拽、文件编辑回传 |
| Mosh | ✅ **自研库**，支持服务端 1.3.0+ | 可自定义 `mosh-server new -s -l LANG=en_US.UTF-8 [-p from:to]` |
| Telnet | ✅ Host 内可添加 | ⚠️ 官方明文警告明文传输 |
| Serial | ✅ 桌面 + 移动 | ⚠️ 官方指定线材：Redpark USB-C Serial Cable (C4-RJ45V) / Lightning Console Cable (L2RJ45V3)；⚠️ 不支持 USB Hub；⚠️ Microsoft Store 版不可用，需官网版 |
| Local Terminal | ✅ 桌面原生 PTY | 默认跟随系统 shell，可在 `Settings > Terminal > Local Terminal Path` 指定；快捷键 `Ctrl/Cmd+L` |

### 2.2 网络路径能力

- **Host Chaining（跳板链）**：可配多个中间主机，连接时 Termius 自动沿链建立 SSH tunnel，一键到达目标。支持在 **Group 级配置同一 host chain 让整组继承**——官方 Pro tip。
- **Proxy**：SOCKS5 / HTTP，含地址、端口、凭据。
- **Agent Forwarding**：Termius 用**自建内置 SSH Agent，不用 OS agent**（官方理由：保持跨平台一致）。连接后用于认证的密钥会被加入该 agent。
- **端口转发**：Local / Remote / Dynamic 三种全支持，**保存为可命名规则**，双击启动、双击停止，可在一个页面看全部活跃规则。三种形态等价于：
  - `ssh -L 127.0.0.1:3336:10.1.30.42:3306 user@host`（取回访问）
  - `ssh -R 127.0.0.1:8080:127.0.0.1:80 user@host`（暴露本地服务）
  - `ssh -D 2080 user@host`（本地起 SOCKS 代理）
  - ⚠️ Remote 转发要求服务端 `GatewayPorts yes`。
  - ⚠️ iOS 上要避开系统保留端口，否则规则不会激活。

### 2.3 落盘与自动保存行为

桌面端输入 IP/port/user/password 后**自动保存 Host**，不需要显式 Save；Group、Key、Snippet 同样自动保存。移动端需点 Save。

---

## 三、终端体验

### 3.1 Workspaces：多会话工作区

把一个"意图"（部署 / 排障 / 巡检）固化成可复用模板。

- **两种视图**，随时切换且不中断会话：
  - **Focus mode**：主视图只显示一个终端，其余在侧栏
  - **Split view**：同时显示全部，**上限 16 个终端**
- **模板捕获 5 类状态**：包含的连接、Tab 名、布局配置、工作目录、**保存时正在运行的命令**。
  > ⚠️ 工作目录与运行命令的跟踪**依赖 Autocomplete 开启**；关掉 Autocomplete 则不显示也不恢复这两项。
- **变更检测**：切换视图、改模板/标签名、调整分屏布局或顺序、改工作目录、活动命令变化都会点亮 tab 上的灰点，`Ctrl/Cmd+S` 保存。未保存就关闭，模板不变。
- 快捷键：`Ctrl+Alt+M / Cmd+Shift+M` 切视图，`Ctrl+Alt+B / Cmd+B` 切广播，`Ctrl/Cmd+S` 保存，均可在 `Settings > Shortcuts` 自定义。
- **仅桌面**（macOS/Windows/Linux），移动端无此功能。

### 3.2 会话状态三色指示灯

这是我最欣赏的细节设计：

| 颜色 | 含义 |
|---|---|
| 🟢 绿 | 终端有未读输出 |
| 🟡 黄 | **需要你输入**（密码、确认、prompt） |
| 🔴 红 | 终端出错或连接失败 |

Focus 模式显示在侧栏，Split 模式显示在 pane 头部。黄点直接回答"我是不是在等人敲 sudo 密码"这个问题。

### 3.3 Command Broadcast：广播输入

workspace 内可把同一输入发给所有活动终端。选中的终端保持输入焦点，Termius 把输入分发给全部。用途：批量健康检查、跨主机改配置、状态校验。支持分屏场景，主输入终端有实心边框高亮。

### 3.4 Autocomplete + Shell Integration

这是官方文档里信息量最大的一页，且**设计明显比一般终端激进**。

**数据来源**：命令历史、文件/目录路径、内置命令及参数、参数描述、 snippet、**检测到密码提示时建议 identities**。无需安装任何第三方包。

**Shell Integration 的实现方式（关键）**：在远程 SSH 会话里，Termius 在 `shell` 通道之外**额外开 `exec` 通道**去取路径和命令历史。

> ⚠️ **这是最值得注意的产品级风险**：官方明示部分服务器会拒绝 exec 通道并**直接断连**，常见于网络设备与收紧过的系统。解法是关掉 Autocomplete，或把服务端 `MaxSessions` 调到 ≥2。也就是说，Autocomplete 这个功能与某些企业环境的兼容性是冲突的。

**限制**：
- 本地终端 shell integration 只支持 `bash` / `zsh`
- 远程要求 OpenSSH 7.2+ 且 shell 为 bash
- **PowerShell 与 CMD 不支持 Autocomplete**

### 3.5 Snippets：云同步的命令库

被官方定位为 "a cloud-synced library of your most-used or proven scripts/commands"。

- 每个 snippet 有 **Action description**（做什么）+ **Script** 两个字段。
- **AI 生成**：在 Action description 里用自然语言描述，点 magic wand 按钮生成脚本填入 Script 字段。
- **四种运行方式**：侧栏 Paste（不执行）/ Run（或双击执行）；从 Autocomplete 输名字触发（**匹配 snippet 名或其脚本内任意文本**）；多主机批量执行；Startup snippet。
- **两种多主机执行路径**：
  - **Snippets 屏幕双击** → 会**新建连接**到所选主机，自动组成一个 workspace，连上后自动执行；`Save targets` 可记住目标集下次预选。要中止就关掉某个 host tab 或整个 workspace tab。
  - **侧栏右键 → `Run in all tabs`** → 在**当前已开的所有终端**里跑（不新建连接）。
- **Startup snippet**：配在 Host 的 `Startup Command` 字段，每次连接自动执行。官方举例：进目录、激活 venv、跑检查、**attach 到已有 tmux 会话**。
- **Snippet Package**：文件夹式组织。
- **Vault 间 Copy to / Move to** 实现团队分享；在共享 Vault 里删 snippet 会删掉所有人的。
- > ⚠️ **不支持变量**。官方 Pro tips 给出的替代方案很务实：用 Host/Group 级**环境变量**间接实现参数化（见 3.6）。

### 3.6 环境变量：官方给的低配"参数化"方案

Host 与 Group 均可设 `KEY=VALUE`，连接时自动下发，机制等同 OpenSSH 客户端 `SendEnv`。

- ⚠️ 服务端 `sshd_config` 必须 `AcceptEnv` 显式放行，否则**静默丢弃**；默认一个都不接受。官方明确警告：某些环境变量可用来绕过受限用户环境，所以不要宽泛放行。
- 官方给的最佳实践正好补上 snippet 无变量的短板：给不同 Host 设同名的 `SERVICE_NAME=nginx` / `gunicorn`，snippet 里写 `sudo systemctl restart $SERVICE_NAME`，一份脚本在各机器上重启各自正确的服务。

### 3.7 会话日志

- 默认**每台主机只保留一条 recent log**，新会话结束就覆盖旧的。要长期保留必须 **Bookmark**（可加备注）。
- 日志跟着 Vault 走；**Local terminal 的日志永远只存 Personal Vault，不同步不给团队**。
- Multiplayer 会话只记录 **owner**，guest 侧不记录。
- ⚠️ **Mosh 会话不被记录**。
- ⚠️ **移动端只记录并后台同步，不能查看**，必须回桌面端看。
- 三种限制（官方 FAQ 明确）：
  - **单条日志不能手动删除**（只能靠新会话覆盖，或关 logging 清空整个 vault）
  - **不能移到别的 Vault**（只能把 host 移过去，旧日志留下，新会话记到新 vault）
  - **没有导出按钮**，只能手动复制粘贴
- 明文出现在终端的内容都会被记录；**交互式密码提示（不回显的）不会被捕获**。

---

## 四、凭据与密钥管理

### 4.1 密钥类型覆盖（这是 Termius 做得最全的一块）

| 类型 | 生成 | 说明 |
|---|---|---|
| Ed25519 / ECDSA / RSA | ✅ 全平台内置 keygen | 支持 passphrase + `Save passphrase` 免提示 |
| **ML-DSA** | ✅ | 后量子签名算法，9.37.0 起 |
| **FIDO2 硬件密钥** | ✅ 全平台（USB / NFC） | 生成 **non-resident** 密钥并**跨设备同步**；可配 `Require User Presence`（触摸即 2FA）、`Require PIN code`、passphrase。需服务端 OpenSSH ≥ 8.4。官方列明支持 YubiKey / Solo / OnlyKey / Google Titan |
| **生物识别密钥（Secure Enclave / TPM）** | ✅ macOS+iOS（Face ID/Touch ID → SEP）、Windows（Windows Hello → TPM） | 私钥在隔离硬件子系统中生成，**连 Termius 和 OS 都无法导出/复制**；连接时请求 SEP/TPM 签名并弹生物识别。⚠️ **因此不同步**——硬件里取不出私钥 |

**一键部署公钥（Export to host）**：选中 key → 选 host → 可选自定义 `SSH keys location` 与 `Filename` → `Export and Attach`。成功后把 key 自动挂到该 host，实现一键连接。FIDO2 与生物识别密钥同样走这条路径。

### 4.2 Sync of keys and passwords 的边界

- 可关 `Sync keys and identities`：此时仅 Personal Vault 的凭据留本地，**但 hosts/groups/snippets/规则等其余数据仍然加密同步，无法完全停止同步**。
- Team Vault 的凭据不受此开关控制；只能在 Host 层选择"共享给团队"还是"要求成员用各自 Personal Vault 的凭据"。
- 生物识别密钥因为物理上同步不了，天然是本地-only 的。

---

## 五、SSH ID（sshid.io）：把"公钥分发"做成 URL

这是 Termius 最近最有意思的产品创新，且**独立于 Termius 本体存在**。

**问题**：多设备 + passkey 化之后，最大的摩擦变成"怎么把每台设备的公钥塞进服务器的 `authorized_keys`"。

**方案**：每台设备登录时生成一组 device-bound 密钥，**只同步公钥**，聚合成一个 URL `https://sshid.io/<handle>`。给任何机器授权只需一条命令：

```bash
curl https://sshid.io/<your_handle> >> ~/.ssh/authorized_keys
```

**细节**：
- 每设备密钥组包含 ECDSA-SK（硬件+生物识别保护）、ECDSA、ED25519、RSA（兼容老设备）。
- 每把 passkey 由用户**自己的 CA 密钥对签发**（CA 私钥在设备上生成）。
- 公钥页同时提供 CA 公钥 + 每把钥匙的证书，因此**任何人可用标准 `ssh-keygen` 三步验证**（校用户身份 → 校签发 CA 指纹一致 → 校证书与该公钥指纹一致），确认公钥确由 Termius 生成。
- 私钥永不出设备、不可导出、不可复制。
- 吊销某设备：在该设备上退出登录，其公钥即从 handle 移除。
- 官方附带一条安全建议值得注意：生物识别只是便利层，**移动端务必设自定义字母数字密码而不是 4/6 位 PIN**，否则 PIN 兜底会削弱硬件安全。

> 产品视角看，SSH ID 实质上把"authorized_keys 分发"从手工/Ansible 流程变成了一个可寻址的身份层。这也解释了为什么 MultiKey 被废弃——MultiKey 的定位被 SSH ID 完全覆盖。

---

## 六、云资源集成与迁移

### 6.1 云同步（按 Group 开启）

AWS、DigitalOcean、Azure 三家的实例可自动导入并随基础设施变化保持更新。在 Group 级开启，可为不同 provider 建不同 Group。官方口径是"available for both free and paid plans"。

### 6.2 导入器矩阵

| 来源 | 导入内容 | 限制 |
|---|---|---|
| **`~/.ssh`** | ssh_config、known_hosts、密钥文件 | ⚠️ `ProxyCommand` **不支持，直接忽略**；`JumpHost` 会转成 Host chain；`IdentityFile` 仅官网直装版可导 |
| **CSV** | label/IP/协议/端口/group/子组/tags/凭据 | 需先下载模板按格式填 |
| **PuTTY** | 连接、隧道、密钥 | Windows 可自动读会话；mac/Linux 需先在 Windows 上 `reg export HKCU\Software\SimonTatham` 生成 `.reg` |
| **MobaXterm** | 会话、文件夹、SSH 隧道 | 导出 `MobaXterm.ini`，支持 `.mobaconf` / `.mxtsession`，可加密 |
| **SecureCRT** | host、group、凭据 | `Tools > Export settings` 出 `.xml` |

全部导入到 **Personal Vault**。

### 6.3 迁移路径的观察

导入做得相当厚（尤其 PuTTY/SecureCRT/MobaXterm 这三家老牌客户），但缺一条对称的**导出**能力——官方文档中看不到一键导出。session log 无导出、hosts 无整体导出，这构成实际上的迁移成本。

---

## 七、移动端：把"手机 SSH"做成了真产品

官方口径：移动端 "can do everything your desktop app can"（Workspaces 除外）。事实层面的差异点：

**手势系统**（这是移动端的核心交互）：
- **方向键**：长按屏幕任意方向拖动 → 同向连续按键，有三档速度，拖动越快越快；或按住空格键滑动
- **Tab**：双击屏幕
- **缩放**：双指捏合改字号
- **粘贴**：长按后 Paste，或三指点击屏幕后点粘贴图标

**Keyboard add-on**：常驻在系统键盘上方，显示扩展键盘前三组热键，**每组 4 键，可重排、可自定义**。

**AI widget**：键盘上方的面板，两种输入模式：
- **AI 模式**：自然语言 → 生成命令 → 可执行或先改再执行。**可把终端里选中的文本作为附加上下文传进去**（选中 → 上下文菜单选 AI）。维护本次会话的 prompt 与生成历史，可回看复用。可在 `Profile → Settings` 里 `Hide the AI widget` 关掉。
- **Paste 模式 + 语音输入**：口述 prompt，可原样执行或编辑后执行。

**图片/文件粘贴直传**：这是移动端独有且很实用的一招——复制图片/文件后在终端里 Paste，**后台通过 SFTP 传到 `/tmp`，自动生成唯一文件名并把路径插进终端输入行**；也可走 SFTP 手动控制目标目录。官方专门强调可用于把文件喂给 Claude Code 之类的 AI agent。

**移动端无的能力**：Workspaces、会话日志查看。

---

## 八、AI 功能全景

Termius 的 AI 不是单一功能，而是**分散在四处的同一个能力的四个入口**：

| 位置 | 形态 | 触发 |
|---|---|---|
| 终端内（桌面） | 命令生成 | 按 ↓ → 自然语言 → 命令落到输入行（不自动执行） |
| Autocomplete | 建议源之一 | 输入时与历史/路径/snippet 并列出现 |
| Snippet 编辑器 | 脚本生成 | Action description 里描述 → magic wand |
| 移动 AI widget | 命令生成 + 语音 + 终端选区作上下文 | 键盘上方面板 |

移动端的 `Paste 模式` 把语音接进来，等于形成"说话 → 成命令 → 执行"的闭环，配合图片直传 `/tmp`，指向的是"**在手机上驱动远端 AI coding agent**"这个明确场景（官方 X 账号也在推 vibe coding from iPhone）。

---

## 九、已知功能缺口（官方文档口径）

按对使用体验的影响排序：

| 缺口 | 官方说明 |
|---|---|
| **`ProxyCommand` 不支持** | 导入 `~/.ssh` 时直接忽略，用 Host chain 替代。路线图上仍有请求 |
| **Snippet 无变量** | 用环境变量间接实现参数化 |
| **Mosh 会话不记录日志** | 明确写在 FAQ |
| **移动端不能查看日志** | 只记录 + 后台同步 |
| **单条日志不可删、不可移 Vault、不可导出** | FAQ 三条明确 No |
| **X11 转发** | 长期缺位，路线图高票未实现 |
| **RDP / VNC** | 不支持 |
| **会话保活依赖服务端 tmux** | 官方博客教学用户用 tmux + `Startup Command` 自动 `tmux attach` |
| **Autocomplete 与收紧的 sshd 冲突** | 额外 exec 通道可能被拒并断连，需 `MaxSessions ≥ 2` |
| **PowerShell / CMD 下无 Autocomplete** | 文档明示 |
| **Local Terminal 在 Mac App Store 与 Snap Store 版缺失** | 沙箱限制，需官网版 |
| **Serial 在 Microsoft Store 版不可用** | 需官网版 |
| **主机整体导出能力缺失** | 文档无对应功能 |

---

## 十、产品设计上值得提取的几点

1. **"引用"而非"复制"是贯穿全局的组织原则。** Identity 被多个 Host 引用、Group 设置被 Host 继承、Key 被 Host 引用、Vault 被日志归属——所有层都是引用关系，改一处全局生效。这是它能hold住"100+ 台主机 + 多设备"体验的根本原因。
2. **状态的显式化做得极好。** 三色会话灯区分"有新输出/等你输入/出错了"，workspace 灰点提示"模板有未保存变更"，登录后 Host 自动保存。用户从不需要猜当前状态。
3. **模板 = 保存时点快照**，包括工作目录和正在跑的命令，这个细节很少见；代价是依赖 Autocomplete，形成功能耦合。
4. **把授权流程压缩成一条 curl**（SSH ID）——不是加功能，而是识别出真正的摩擦点（authorized_keys 分发）并消掉它。
5. **免费层已经相当完整**：协议、SFTP、端口转发、广播、多主机 snippet 执行、FIDO2、SSH 证书、环境变量、后量子算法全部免费；付费墙只压在同步与团队协作上。
6. **但兼容性代价被藏得较深**：`exec 通道断连`、`App Store 版功能缺失`、`Serial 需特定线材`、`PowerShell 不支持`——这些都在文档里，但都是"用了才发现"的类型。对要做同类产品的人来说，这些正是不该照抄的地方。

---

## 附：信息来源

- 官方文档（逐页通读，`.md` 版本）：`docs.termius.com`，重点为
  - `getting-started/what-is-termius`（核心模型）
  - `getting-started/import-existing-hosts`（导入矩阵）
  - `organize-and-connect-to-hosts/connecting-to-a-server`（协议与代理/跳板/Agent Forwarding）
  - `organize-and-connect-to-hosts/port-forwarding-and-tunneling`（三种转发）
  - `organize-and-connect-to-hosts/groups-and-tags`（继承与标签）
  - `organize-and-connect-to-hosts/session-logs`（日志模型）
  - `organize-and-connect-to-hosts/managing-files-with-sftp`（文件管理）
  - `terminal/workspaces`、`terminal/snippets`、`terminal/autocomplete-and-shell-integration`、`terminal/environment-variables`、`terminal/mobile-terminal`
  - `keychain/ssh-keys-and-certificates`、`keychain/identities`
  - `ssh-id-passkeys-for-ssh/what-is-ssh-id`、`ssh-id-passkeys-for-ssh/ssh-id-security`
- 官方更新日志：`docs.termius.com/changelog/desktop`（版本至 10.1.0）
- 官网功能页：`termius.com/ssh-id`、`termius.com/security`
