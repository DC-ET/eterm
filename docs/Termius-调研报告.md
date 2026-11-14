# Termius 产品调研报告

> 调研日期：2026-09-20
> 信息来源：termius.com 官网 / prices、docs.termius.com 官方文档、官方 changelog、GitHub、Reddit / Hacker News / V2EX、App Store / Google Play、NVD / SentinelOne、第三方数据商（GetLatka / Sensor Tower / Tracxn，均为估算口径）
> 说明：文中价格为 2026-09 时点官网数据；营收、下载量等为第三方估算，已逐处标注。

---

## 一、一句话结论

Termius 不是一个"更好的 SSH 客户端"，而是**把 SSH 凭据做成了密码管理器**。它的核心竞争力不是连接能力（连接能力免费且不限量），而是"跨 5 端的加密 Vault 同步"；它的护城河和它的骂名来自同一个设计。

---

## 二、公司与商业基本面

| 维度 | 事实 | 来源 |
|---|---|---|
| 前身 | **Server Auditor**（2011 年 Roman Kudiyarov 为在 iPhone 上监控 C++ 编译进度而写的个人项目） | https://termius.com/about |
| 公司成立 | Termius Corporation，2019-12；2019-06 以 **YC W19** 身份 Launch HN | https://news.ycombinator.com/item?id=20118727 |
| 创始人 | Roman Kudiyarov（CEO）、Dmitry Lyafar，相识于西伯利亚鄂木斯克，曾做 PC 游戏与外包公司 | 同上 |
| 融资 | 仅 1 轮种子轮，累计约 **$2.7M**（Tracxn 估算），金额未公开 | https://tracxn.com/d/companies/termius/ |
| 团队 | 分布式远程小团队，约 30 人（Crunchbase 33 / GetLatka 29）；办公地披露为美国 + 新西兰 | https://www.crunchbase.com/organization/termius |
| 规模 | 官网称 **"Trusted by 2,000,000+ professionals"**；GloriaOps 页面亦用该口径 | https://gloriaops.com/ |
| ARR | 2021 ~$1.8M → 2023 ~$2.2M → 2024 ~**$4M**（GetLatka 估算，非审计） | https://getlatka.com/companies/termius |
| 收入结构 | Sensor Tower 估算 iOS 单端月下载约 70K、月营收约 **$200K**，即移动端占总 ARR 一半以上 | https://app.sensortower.com/overview/549039908 |

**关键判断**：约 30 人团队、$2.7M 融资撬动约 $4M ARR，是典型的**资本效率极高的 PLG 生意**。不打广告增长（Sensor Tower 观察），靠口碑 + 学生/开源免费通道获客。

---

## 三、产品结构：到底在卖什么

### 3.1 五端全覆盖，但无 Web 端

| 平台 | 形态 | 说明 |
|---|---|---|
| macOS / Windows / Linux | **Electron** 桌面端（10.0.6 起 Electron 43） | 直装 + 应用商店；macOS App Store 版**无本地 PTY 终端**（沙箱限制） |
| iOS / iPadOS | 独立 App | 官方称"移动端可做桌面端能做的一切"；键盘附加键、Live Activities |
| Android | 独立 App | UI 于 2022 年单独重构后与新体系对齐 |
| Web | **无独立 Web 终端** | 仅有 account.termius.com 账户门户 |

桌面端三端共享同一套加密内核与 Vault 数据模型，但 **UI 不共享**（2024 年 Desktop / iOS / Android 分别发布三套 redesign）。

### 3.2 功能矩阵（现行档位）

档位：**Starter（免费）/ Pro / Team / Business / Enterprise**。（官方体系不存在"Signature"档，那是混淆信息。）

| 能力 | 免费 Starter | Pro | Team+ |
|---|---|---|---|
| SSH / SFTP / Mosh / Telnet / Serial / 本地终端 | ✅ | ✅ | ✅ |
| 端口转发（本地/远程/动态）、代理、Agent Forwarding、Host Chains | ✅（**10.1.0 起全部下放免费**） | ✅ | ✅ |
| **主机数量** | **无上限，且允许商用** | ✅ | ✅ |
| Local vault | ✅ | ✅ | ✅ |
| AI Autocomplete / AI 命令生成 | ✅ | ✅ | ✅ |
| FIDO2 / SSH 证书 / 多主机 Snippet 执行 / Broadcast 输入 | ✅（均已免费化） | ✅ | ✅ |
| 后量子 KEX（mlkem768x25519）、ML-DSA 签名 | ✅（9.25.0 / 9.37.0） | ✅ | ✅ |
| **跨设备云同步（Personal Cloud Vault）** | ❌ | ✅ | ✅ |
| **Snippets 自动化 / Session Logs** | ❌ | ✅ | ✅ |
| **Team Vault / 终端 Multiplayer / 共享日志** | ❌ | ❌ | ✅ |
| **自定义 Vault 细粒度权限** | ❌ | ❌ | Business+ |
| **SAML SSO** | ❌ | ❌ | Business 的 add-on |
| SOC 2 报告 / 定制合同 / 专属客户成功 | ❌ | ❌ | Business / Enterprise |

**免费版唯一本质限制：不支持跨设备同步。** 主机数不限、SFTP 不限、端口转发不限、AI 补全不限、明确允许商用。

### 3.3 定价

| 档位 | 年付价 | 月付 | 计费 |
|---|---|---|---|
| Starter | 免费 | — | 允许商用 |
| **Pro** | **$10/月**（≈$120/年） | ≈$19.99/月（第三方口径） | 单用户 |
| Team | **$20/席/月** | — | **最少 2 席** |
| Business | **$30/席/月** | — | 席位 |
| Enterprise | 定制 | — | 联系销售 |

- Team/Business **只能走官网账户门户信用卡**，不支持 PayPal / 应用商店。
- 免费拿付费档两条正规通道：**GitHub Student Pack**（Pro+Team 全功能）、**开源维护者计划**（仅 Team 账户、不可商用）。

---

## 四、技术架构与安全模型

### 4.1 技术栈

- **桌面端 = Electron 43**，Terminal 前端疑似自维护 xterm.js fork（未官方确认）；Termius GitHub 组织有 `termius/flutter_rust_bridge` fork，**高度疑似移动端为 Flutter + Rust，但官方从未公开移动端架构**。
- 加密内核三端统一：**libsodium 1.0.20 + Botan 3.2.0**，均为自研 C++ binding。
- SSH / Mosh / Telnet / Serial / SFTP 全自研（Mosh 为自研库）；**自建 SSH Agent，不用 OS agent**。
- **offline-first，Termius 不是代理**，SSH 流量不经云端；云端只同步加密后的 Vault。
- 服务端栈：Django + Celery + gRPC（从官方 fork 的 `django-reversion`、`pylint-celery` 推断）。

### 4.2 加密模型（密码管理器级别）

来源（唯一权威）：https://docs.termius.com/security/encryption-overview

- 认证：改造版 **SRP6a**，synthetic 后用 **Argon2id**（`ARGON2ID13`）派生——**不是 PBKDF2，不用 AES-GCM**。
- 对称：**XSalsa20-Poly1305**（`crypto_secretbox`）；公钥封装：**X25519-XSalsa20-Poly1305**（`crypto_box`）。
- Personal Vault = 混合加密：账户密钥对 → 派生个人加密密钥 → 加密全部数据；**私钥由用户 encryption password 加密**，密码永不联网、永不与数据同存。丢失即不可恢复（Termius 也无法恢复）。
- Team Vault = **成员公钥封装 vault key + Owner 私钥签 MAC**，标准密码学做法，云侧无法读明文。
- Argon2id 的 opslimit/memlimit **具体数值未公开**（只给了 libsodium 交互级参数名）。
- 本地存储：Android = Keystore 加密的 shared preferences；Desktop = OS Keychain 加密的 Electron IndexedDB（**localStorage 兜底**）。**iOS 的存储机制在官方加密文档中缺失**。

### 4.3 会话保活：不是产品能力

Termius **不提供 tmux/nohup 式服务端会话保活**。官方博客反而**教学用户在远端用 tmux**："Run your AI agent inside tmux. The session keeps running on the server side, independent of your SSH connection."（https://termius.com/blog/8-tips-for-using-ai-agents-on-mobile-in-termius ）
连接层韧性靠 **Mosh**；移动端后台保活依赖 OS 机制（iOS Live Activities / Android 关电池优化），实际仅 20-30 秒。

### 4.4 合规与企业能力

| 项 | 状态 |
|---|---|
| **自托管 / On-prem** | ❌ **明确不提供**。官方原文："Termius requires no setup on-premises." 数据中心在 **AWS US**，Trust Center 称 "primarily hosted on AWS US"，**未找到 EU 数据驻留选项** |
| **SOC 2 Type II** | ✅（Trust Center 提供 2025 报告） |
| ISO 27001 | ❌ 未找到 |
| HIPAA | ❌ 未找到 |
| **SCIM / 目录同步** | ❌ 未找到任何公开信息 |
| SAML SSO | ✅ Business add-on，走 WorkOS；IdP 覆盖 Okta/Azure AD/Google/Keycloak/CyberArk 等 18+ |
| 管理审计日志 | ❌ 只有 **team session logs**（终端会话日志，只读不可删），无传统 SaaS 管理操作审计 |

---

## 五、已知风险与争议（这是最该关注的部分）

### 5.1 CVE-2024-57061 — Electron Fuses 加固不足，CVSS 9.8 CRITICAL

- 影响 **Termius 9.9.0 – 9.16.0**（2025-03-19 公开，被 CISA 漏洞周报收录）。
- 第三方对 `Termius.app` 跑 `npx @electron/fuses read` 的实测显示：`RunAsNode: Enabled`、`EnableCookieEncryption: Disabled`、`EnableEmbeddedAsarIntegrityValidation: Disabled`、`OnlyLoadAppFromAsar: Disabled`。
- 同类对照：Notion 的 fuses 全部收紧。**对一个持有大量生产环境 SSH 凭据的客户端，本地植入的后果被显著放大。**
- 未找到 Termius 的官方修复公告/致谢。
- https://nvd.nist.gov/vuln/detail/CVE-2024-57061 ｜ https://www.cisa.gov/

### 5.2 供应链：Termius 已成攻击者重点仿冒目标

2025-05 SentinelOne 发现 macOS.ZuRu 木马化 `Termius9.5.0.dmg`（植入物进 `Termius Helper.app`，LaunchDaemon 持久化，每小时回连 Khepri C2）。这**不是 Termius 自身缺陷**，但说明它已是开发者工具的"高价值仿冒目标"。
https://www.sentinelone.com/blog/macos-zuru-resurfaces-modified-khepri-c2-hides-inside-doctored-termius-app/

### 5.3 社区三大持续争议

1. **价格与订阅制**：$120/年买 SSH 客户端被 Reddit / V2EX 反复攻击；且**区域定价不一致**（官网 $120/年 vs App Store 内购曾显示 $169/年 vs 土耳其区 30 多一年）被截图对比形成"价格歧视"观感。无任何买断档。
2. **同步可靠性**：老用户反馈 "new hosts don't save, configs and keys disappear"（r/selfhosted，**搜索摘要级证据，直连 403，不宜过度断言**）。这是信任层面的最危险信号——一旦崩塌用户会带怒气迁移。
3. **Electron 占用**：被反复与高 CPU / 8GB 内存不足关联；同类 Tabby 被吐槽"M1 Max 也太慢、启动 3 秒"。

### 5.4 免费版曾收紧，现在在反向松绑（重要趋势）

近年 Termius 持续把付费能力下放免费层：FIDO2（2024）→ Broadcast（2024）→ 多主机 Snippet 执行（2025）→ SSH 证书 + 环境变量（2025）→ **Proxy / Agent Forwarding / Host Chains / Serial 全部免费（10.1.0）**。同时 **MultiKey 被废弃**，迁移到 SSH ID。免费层做获客、只靠 sync/team/合规变现。

---

## 六、演进方向

桌面端当前版本 **10.1.0**（9.x 时代结束），周更~双周更。三条清晰的战略线：

### 6.1 从 SSH 客户端 → 多协议基础设施访问入口
路线图投票榜前几名暴露意图：**RDP（1,629 票）、X11 转发（1,174 票，五年前就在榜上至今未做）**、CyberArk / Teleport PSM 连接、COM 端口、**中文本地化（2,285 票，最高）**。意向是成为 bastion / PAM 邻域产品。
已知短板：**不支持 `ProxyCommand`**（导入时直接忽略，用 Host Chain 替代）、无 Tailscale 内置、无干净一键导出。

### 6.2 从工具 → Agent 云产品（最大变量）
- 内置 **AI 命令生成**（免费）、**AI Snippet**、对话式 **AI Agent**（beta，明确声明不访问密码与密钥）。
- **Gloria**（2025-08 首发，experimental）→ 已独立为 **GloriaOps**（gloriaops.com）。产品逻辑极具针对性：*"Coding agents are built for file edits that you can just `git reset`... Infrastructure monitoring doesn't work like that."*
- GloriaOps 的安全设计值得注意：**不生成 shell 命令**，每个 target（SSH / Cloud / DB）配 purpose-built commands，read-only by default，任何变更以 plan 形式显式审批 + 声明 capabilities。支持导入 `~/.ssh/config`。
- **当前 Gloria 不接 Vault**，需手动加基础设施 → 长期可能演化为独立 Agent 云产品，甚至改变 vault 为中心的架构。

### 6.3 自动化 / IaC 化
**API Bridge**（REST，Team 起）+ **Ansible role**（`termius.termius`）+ AWS/Azure/DO/GCP 云同步，把 Vault 变成可编程对象，是抬高 Team/Business 客单价的关键抓手。

---

## 七、对国产 / 自研终端产品的启示

### 值得抄的

1. **免费层不卡主机数、允许商用**。这是 Termius 口碑的地基；反例是社区抱怨"不缴费似乎 sftp 都用不了"。
2. **全平台一致性是被低估的护城河**。至少做到三桌面 + iOS。
3. **同步做核心卖点，但把付费换成用户自有存储**。Netcatty 用 GitHub Gist / S3 / OneDrive / WebDAV 六种端到端加密同步，同时拿到 Termius 的卖点和"数据自主"的舆论高地（https://www.v2ex.com/t/1195002）。收费点后移到团队 / 审计 / 企业功能。
4. **免费层做 AI 钩子，进阶做门槛**。Termius 比 Warp 激进改价（2025-10-30 合并为 $20/月，Reddit 爆发）安全得多。
5. **合规三件套前置**（SOC 2 + 集中密钥 + 审计），并**保留买断档**（Royal TS €49、MobaXterm $69、Prompt 3 $99 都提供反订阅选择）。

### 必须避开的坑

1. **不要纯订阅且区域定价不一致** —— 这是 Termius 被攻击的根因。
2. **必须提供一键导出 + 标准格式（ssh config / JSON）+ 本地优先存储**。Termius 缺开放 API，已直接导致用户转向开源（"Open source helped me fixed all that"）。
3. **不要用 Electron 硬扛**。Termex 直接把"再见 800MB"当卖点；考虑 Tauri/Rust 或原生，安装包控制在百 MB 内、冷启动 1 秒内。
4. **不要长期停更**。WindTerm（停在 prerelease、作者失踪）与 **JuiceSSH（2025-12 从 Google Play 下架、Pro 验证大量失效）** 是最惨案例：许可证服务器一关，付费用户立刻变"付费受害者"。
5. **Electron Fuses 必须全部收紧**（这是 9.8 分 CVE 的直接教训）。
6. **不要把盈利押在单一平台** —— Termius iOS 端占 ARR 一半以上，商店政策风险高度集中。

---

## 八、信息缺口（未找到公开确凿证据，不作猜测）

| 缺口 | 说明 |
|---|---|
| 团队规模 / 轮次金额 | 官方未披露；Crunchbase/LinkedIn 付费墙后可能有 |
| 逐次涨价时间线 | 仅能证明"多次调价"与"约 $8→$10"温和上调；精确时间线需查 Wayback Machine 快照 |
| 移动端 UI 技术栈 | 仅 `flutter_rust_bridge` fork 一个间接信号，官方无任何架构博客 |
| 桌面端终端模拟器组件 | 疑似自维护 xterm.js fork，无法确认 |
| Argon2id 具体参数值 | 只有 libsodium 交互级参数名 |
| iOS 本地密钥存储机制 | 官方加密文档只列 Android 和 Desktop |
| SCIM / EU 数据驻留 / ISO 27001 / HIPAA | 均未找到 |
| 官方是否披露过数据泄露 | 仅能确认"未找到公开记录" |
| macOS App Store 版本地终端 | 官方称"unavailable in the App Store version"，沙箱限制 |
