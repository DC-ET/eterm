# eterm · 技术方案

> 版本：v1.1 ｜ 日期：2026-11-14
> **v1.1 变更**：应用户决策，服务端实现由 Go 改为 **Node/TS**（Fastify 5 + ws + mysql2 + node-argon2 + vitest）。API 形状、同步语义、DB schema、加密格式（AES-256-GCM `v1:`）全部保持不变——客户端与存量数据零影响。Go 版已归档于 git 历史（提交 4d049e5 之前）。§3 中与语言绑定的工程细节（chi/sqlc/goose 的描述）为历史口径，SQL DDL 与 API 契约部分仍然准确，TS 实现见 `server/src/`。
> 上游文档：[eterm-产品设计与需求文档-v2.md](../eterm-产品设计与需求文档-v2.md)（下称 PRD）。本文回答"怎么做"，所有决策以上游 PRD §10 已拍板项为准，不再重复论证"为什么"。
> 范围：系统架构、服务端/客户端工程与技术设计、同步协议、安全设计、测试策略、M0 spike 验收标准、里程碑任务分解。

---

## 1. 技术栈总览

| 层 | 选型 | 版本基线 | 关键理由 |
|---|---|---|---|
| 服务端语言 | **Node/TS**（v1.1 起，原 Go 已归档） | Node 22 + TS 5.7 | 用户维护性优先；协议/DB/加密契约与 Go 版逐字节对齐 |
| 服务端框架 | `fastify` + `@fastify/websocket` | v5 / v11 | TS 类型完善、生态成熟；WS 升级头内建 |
| 数据访问 | `mysql2/promise` | v3 | 连接池 + 事务；JSON/BINARY 列处理直接 |
| 口令哈希 | `argon2`（node 原生绑定） | v0.41 | Argon2id；PHC 格式与 Go 版语义一致（t=2，下限约束） |
| 测试 | `vitest` | v3 | 与 Go 测试矩阵一一对应（22 项） |
| 运行 | `tsx`（dev/prod 通用） | v4 | 免构建；deploy = 源码 + npm ci |
| WebSocket | `coder/websocket` | latest | 维护活跃、API 简洁（gorilla 之后的默认选择） |
| 口令哈希 | `golang.org/x/crypto/argon2` | — | Argon2id（PRD §2.2） |
| 字段加密 | 标准库 `crypto/aes` + GCM | — | AES-256-GCM，无第三方依赖 |
| 日志 | `log/slog` | — | 标准库结构化日志 |
| 数据库 | MySQL | 8.x（已有实例） | utf8mb4 / InnoDB / JSON 类型 |
| 反向代理 | Caddy | 2.x | Let's Encrypt 自动签发续期，配置极简 |
| 客户端 UI | Flutter | 3.24+ | 一套代码 Mac + Android（PRD §2.3） |
| 客户端核心 | Rust | stable (1.82+) | SSH/同步/加密核心，平台无关可单测 |
| FFI 桥 | `flutter_rust_bridge` | v2 | 官方代码生成 + cargokit 构建集成 |
| SSH | `russh` / `russh-keys` | 0.45+ | Rust 生态最成熟 SSH 实现 |
| 本地存储 | `rusqlite` | latest | 单文件；敏感字段应用层加密（见 §4.3） |
| Rust 异步 | `tokio` | 1.x | russh 基于 tokio |
| 终端渲染 | `xterm.dart` | latest | Flutter 生态终端组件；IME 为 M0 验证项 |
| 状态管理 | `riverpod` | 2.x | 编译期安全、依赖注入与状态一体 |
| 路由 | `go_router` | latest | 声明式路由，桌面/移动通吃 |
| 本地安全存储（Flutter 侧） | `flutter_secure_storage` | latest | macOS Keychain / Android Keystore 封装 |

版本基线为 M0 启动时的最低要求，锁版本以 `go.mod` / `pubspec.lock` / `Cargo.lock` 为准。

---

## 2. 系统总体架构

```
┌────────────────────────────────────────────────────────────┐
│ 客户端（Mac / Android，Flutter + Rust core 同构）             │
│                                                            │
│  Flutter UI ──── riverpod 状态 ──── go_router 路由           │
│      │  (xterm.dart 终端 / 列表 / 双面板 / 表单)              │
│      │                                                     │
│      ▼ FFI (flutter_rust_bridge v2, 流式边界)                │
│  ┌─────────────────────── Rust core ───────────────────┐   │
│  │ api/      导出给 Dart 的门面（连接、会话、同步控制）      │   │
│  │ store/    本地 SQLite + 字段加密 + 同步状态机           │   │
│  │ sync/     pull/push 引擎、cursor、冲突合并             │   │
│  │ ssh/      russh 会话池、跳板链、代理、端口转发           │   │
│  │ sftp/     传输队列、断点续传                            │   │
│  │ keygen/   密钥生成/导入/导出                            │   │
│  └─────────────────────────────────────────────────────┘   │
└──────────┬──────────────────────────────┬──────────────────┘
           │ 同步面 HTTPS + WSS            │ 数据面 SSH/SFTP 直连
           ▼                              ▼
┌─────────────────────────┐      ┌──────────────────┐
│ 中枢 eterm serve (Go)    │      │ 目标服务器 (N 台)  │
│ 127.0.0.1:8080          │      │ sshd :22          │
│  ├─ api/   auth/device  │      └──────────────────┘
│  ├─ sync/  pull/push/ws │
│  ├─ store/ sqlc→MySQL   │──► MySQL 8 (127.0.0.1:3306)
│  └─ crypto/ 字段加密      │    （仅本机监听）
└──────────┬──────────────┘
           ▼
      Caddy :443 (Let's Encrypt, 公网唯一暴露面)
```

三条铁律（对应 PRD §2.1）：
1. **同步面**只有上图左侧一条链路；任何功能实现若隐式引入"客户端→中枢→目标"的路径即为架构违规。
2. **数据面**永远客户端直连目标；`ssh/` 模块是数据面唯一入口。
3. 客户端**本地库是离线 working set**：中枢不可达时，除同步外的一切功能照常工作。

仓库布局（monorepo）：

```
eterm/
├── server/            # Go 中枢
├── client/
│   ├── app/           # Flutter 工程（含 macos/ android/ 平台目录）
│   ├── rust_core/     # Rust crate（frb 集成）
│   └── rust_builder/  # frb cargokit 桥接工程
├── docs/
├── deploy/            # Caddyfile、systemd unit、备份脚本
└── Makefile           # 统一构建入口
```

---

## 3. 服务端设计

### 3.1 工程结构

```
server/
├── cmd/eterm/main.go            # 入口：serve / create-user / migrate 子命令
├── internal/
│   ├── config/config.go         # env 解析（caarlos0/env），启动时校验必填项
│   ├── api/                     # HTTP 层
│   │   ├── router.go            # chi 路由 + 中间件链
│   │   ├── middleware.go        # 认证、IP 白名单、限流、审计、recover
│   │   ├── auth_handlers.go     # login / logout / me
│   │   ├── device_handlers.go   # 设备列表 / 吊销
│   │   └── sync_handlers.go     # pull / push / ws
│   ├── auth/                    # Argon2id、token、失败锁定
│   ├── syncengine/              # pull/push 业务、校验钩子、rev 分配
│   ├── store/                   # sqlc 生成层 + queries/*.sql
│   ├── crypto/field.go          # seal/open（AES-256-GCM）
│   └── audit/                   # audit_events 写入
├── migrations/*.sql             # goose
├── sqlc.yaml
└── go.mod
```

子命令设计（注册不开放公网端点，见 §3.5）：
- `eterm migrate` — 执行迁移
- `eterm create-user --username <name>` — 交互输入口令，创建首个管理员
- `eterm serve` — 启动 HTTP 服务（默认仅监听 `127.0.0.1:8080`，公网暴露交给 Caddy）

### 3.2 数据库设计

约定：主键 `id BINARY(16)` 存 **UUIDv7**（时间有序，索引友好）；**客户端离线生成实体 id**，推送无需服务端分配——这是离线优先的关键设计。时间列 `DATETIME(3)` 存 UTC。字符集 `utf8mb4`，引擎 InnoDB。

同步实体公共列（下表不再重复）：

```sql
rev         BIGINT NOT NULL,        -- 该实体当前版本号，取自 changes.id
created_at  DATETIME(3) NOT NULL,
updated_at  DATETIME(3) NOT NULL,
deleted_at  DATETIME(3) NULL        -- 软删标记（tombstone）
```

```sql
-- 账户与会话
CREATE TABLE users (
  id            BINARY(16) PRIMARY KEY,
  username      VARCHAR(64) NOT NULL UNIQUE,
  pwd_hash      VARCHAR(255) NOT NULL,      -- PHC 格式 $argon2id$v=19$...
  failed_count  INT NOT NULL DEFAULT 0,
  locked_until  DATETIME(3) NULL,
  created_at    DATETIME(3) NOT NULL
);

CREATE TABLE devices (
  id           BINARY(16) PRIMARY KEY,
  user_id      BINARY(16) NOT NULL,
  name         VARCHAR(64) NOT NULL,
  platform     VARCHAR(32) NOT NULL,        -- macos / android / ...
  token_hash   BINARY(32) NOT NULL UNIQUE,  -- SHA-256(token)，token 本身不落库
  created_at   DATETIME(3) NOT NULL,
  last_seen_at DATETIME(3) NULL,
  revoked_at   DATETIME(3) NULL
);

-- 同步实体（vault_id 冗余便于过滤；MVP 仅一个 personal vault）
CREATE TABLE vaults (/* id, name, scope, owner_id, 公共列 */);
CREATE TABLE host_groups (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  parent_id BINARY(16) NULL, label VARCHAR(128) NOT NULL,
  settings_json JSON NULL, sort INT NOT NULL DEFAULT 0,
  -- 公共列
  INDEX idx_vault (vault_id), INDEX idx_parent (parent_id)
);
CREATE TABLE hosts (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  group_id BINARY(16) NULL, label VARCHAR(128) NOT NULL,
  hostname VARCHAR(255) NOT NULL,
  tags JSON NOT NULL,            -- string 数组
  icon VARCHAR(64) NULL, notes TEXT NULL,
  settings_json JSON NULL,
  INDEX idx_vault_group (vault_id, group_id)
);
CREATE TABLE host_protocols (
  id BINARY(16) PRIMARY KEY, host_id BINARY(16) NOT NULL,
  kind ENUM('ssh','sftp','telnet','serial') NOT NULL,
  config_json JSON NOT NULL, sort INT NOT NULL DEFAULT 0,
  INDEX idx_host (host_id)
);
CREATE TABLE identities (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  username VARCHAR(128) NOT NULL,
  password_enc VARBINARY(1024) NULL,   -- 加密字段见 §3.6
  key_id BINARY(16) NULL,
  INDEX idx_vault (vault_id)
);
CREATE TABLE ssh_keys (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  key_type VARCHAR(32) NOT NULL,       -- ed25519/ecdsa_p256/rsa/...
  private_enc VARBINARY(16384) NOT NULL,
  cert_enc VARBINARY(16384) NULL,
  passphrase_enc VARBINARY(1024) NULL,
  public_key TEXT NOT NULL,
  fingerprint VARCHAR(128) NOT NULL,
  origin ENUM('generated','imported','fido2','biometric') NOT NULL,
  key_version INT NOT NULL DEFAULT 1,  -- 不可变版本化：修改=新 version 行
  superseded_by BINARY(16) NULL,       -- 指向新版本
  INDEX idx_vault (vault_id)
);
CREATE TABLE known_hosts (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  hostname VARCHAR(255) NOT NULL, key_type VARCHAR(32) NOT NULL,
  key_enc VARBINARY(2048) NOT NULL, comment VARCHAR(255) NULL
);
CREATE TABLE port_rules (
  id BINARY(16) PRIMARY KEY, vault_id BINARY(16) NOT NULL,
  host_id BINARY(16) NOT NULL, label VARCHAR(128) NOT NULL,
  kind ENUM('local','remote','dynamic') NOT NULL,
  bind_addr VARCHAR(64) NOT NULL DEFAULT '127.0.0.1',
  local_port SMALLINT UNSIGNED NULL,
  remote_host VARCHAR(255) NULL, remote_port SMALLINT UNSIGNED NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE
);
-- 同步核心：append-only 变更表。rev = 本表自增 id，全局单调。
CREATE TABLE changes (
  id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  entity_type ENUM('host_group','host','host_protocol','identity','ssh_key',
                  'known_host','port_rule') NOT NULL,
  entity_id   BINARY(16) NOT NULL,
  vault_id    BINARY(16) NOT NULL,
  actor_device BINARY(16) NULL,       -- 哪台设备产生的变更
  ts          DATETIME(3) NOT NULL,
  INDEX idx_cursor (id)
);

CREATE TABLE audit_events (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  ts DATETIME(3) NOT NULL,
  actor_user BINARY(16) NOT NULL,
  actor_device BINARY(16) NULL,
  action VARCHAR(64) NOT NULL,         -- login / device.revoke / sync.push / ...
  target_type VARCHAR(64) NULL, target_id BINARY(16) NULL,
  detail_json JSON NULL,
  ip VARCHAR(45) NULL
);
```

设计说明：
- **rev 分配**：push 事务内 `INSERT changes` 取得自增 id → 更新实体行 `rev = changes.id` → 同事务提交。读端 `pull` 按 `changes.id > cursor` 扫描，天然全局有序。
- **`ssh_keys.key_version`**：私钥内容不可变（PRD §3.4 同步协议）。"修改私钥" = 新行（新 id）+ `superseded_by` 链；引用方（Identity/Host）更新指向。彻底消灭密钥并发写冲突。
- `changes` 不存数据快照，pull 时按 `entity_id` 回查实体表当前状态——同实体高频修改天然去重，且避免快照膨胀。
- `GROUP` 是保留字，表名用 `host_groups`；跨实体引用（如 `host.group_id`、`identity.key_id`）不做外键（同步系统的一致性由客户端 merge 逻辑保证，服务端仅校验类型）。
- `snippets`/`snippet_packages` 两表在已部署库中保留（Snippets 需求已移除，实体注册删除、不再同步；不删表、不写 ALTER 迁移，保持生产与新建库 schema 一致），`changes.entity_type` ENUM 中的 snippet 值同为保留兼容。
- 单表容量评估：单人数百主机 + 日志外置，所有表远低于千万级，无需分区。

### 3.3 API 设计

所有接口前缀 `/api/v1`，JSON over TLS。**数据 CRUD 不设独立 REST 端点——一切写操作经 push、一切读经本地库 + pull**（CRUD 即同步，单一管道便于校验、审计与冲突控制）。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/auth/login` | body: `{username, password, device_name, platform}` → `{token, device_id, user}`。新设备自动注册 |
| POST | `/auth/logout` | 吊销当前 token（设备保留，重新登录复用 device 记录） |
| GET | `/me` | 当前用户与 vault 概要 |
| GET | `/devices` | 设备列表（含 last_seen_at） |
| DELETE | `/devices/{id}` | 吊销设备（软删：置 revoked_at；该设备 token 立即失效） |
| GET | `/sync/pull?cursor={rev}&limit={n}` | 增量拉取：`{cursor, has_more, changes:[{entity_type, entity_id, op, rev, ts, data}]}`；`data` 为解密后的实体 JSON；`op ∈ {upsert, delete}` |
| POST | `/sync/push` | 批量推送：`{changes:[{entity_type, entity_id, base_rev, op, data}]}` → 逐条 `{status: ok\|conflict\|rejected, rev?, server_data?}` |
| GET | `/ws` | WebSocket 通知通道（见下） |

**push 语义**（服务端逐条处理，包在同一事务组不跨条）：
1. `base_rev` 校验：客户端所见版本。`op=upsert` 且实体不存在 → 视为新建（`base_rev=0`）。
2. 版本不符 → `conflict` + 附服务端当前 `server_data`；客户端按 **LWW（updated_at 字段级）** 合并后重推，最多 3 轮，仍冲突则入队人工处理（单用户场景几乎不发生）。
3. 校验钩子按 `entity_type` 执行（如 Host：hostname 非空、port 1–65535、kind 合法枚举）。
4. 成功 → upsert 实体行 + INSERT changes（`actor_device` 取认证上下文）→ 返回新 `rev`。
5. `op=delete` → 置 `deleted_at` + 写 changes tombstone。

**WS 通知**：连接后服务端推送 `{"type":"change","rev":"<latest>"}` 单一帧型；客户端收到后自行调 pull。服务端不做数据推送；**订阅按 vault 过滤**（2026-11-27 评审 BUG-1：通知面与数据面同受租户边界约束，他 vault 的 push 不唤醒本 vault 客户端）。心跳：服务端 30s ping，两分钟无 pong 断开。重连由客户端指数退避负责。

**导入导出（M3）**：`POST /import/ssh-config`、`POST /import/csv`、`GET /export/all?format=json|yaml`、`GET /export/ssh-config`。解析/生成实现为无状态纯函数，置于 `internal/ioconv/`；客户端 UI 触发，结果经同步通道收敛到各端。导出含凭据时要求客户端侧二次确认（PRD F9）；`ProxyCommand` 导入时忽略并返回忽略清单（PRD F9.2）。

**应急中转接口位**（PRD §2.5 已拍板"不做，仅预留"）：`/api/v1/relay` 路径与 `ETERM_RELAY_ENABLED` 配置项在架构文档中占位，MVP 不注册路由、不实现；未来若立项（Web 壳或网络受限兜底）在此扩展，届时需独立安全评审。

**拉取分页**：`limit` 默认 200、上限 1000；`has_more=true` 时客户端续拉直至追平，再切换到"WS 通知驱动"的静默态。

### 3.4 同步协议状态机（客户端侧）

```
启动 → [cursor 缺失/本地库损坏] → 全量对账: cursor=0 拉全量 → 应用变更
     → [cursor 存在] → 增量追平 pull 循环
     → 稳常态：WS 通知 → pull；本地写操作 → push 队列（先写本地库标记 dirty）
推失败（网络）→ 退避重试，期间新写操作继续排队（离线可用性的保证）
推冲突 → LWW 合并 → 重推（≤3 轮）
收 tombstone → 本地软删（密钥历史版本除外：仅解除引用，不删行）
```

协议一致性测试见 §7。

### 3.5 认证与安全基线

| 项 | 实现 |
|---|---|
| 口令哈希 | Argon2id（time=1, memory=64MB, threads=4），PHC 格式入库；pepper 来自 env（拼接后哈希） |
| token | 32B 随机 → base64url 给客户端；服务端存 SHA-256。Lifetime 无限期（设备模型），靠吊销管理；`last_seen_at` 每 24h 更新 |
| 失败锁定 | 连续 5 次失败 → `locked_until = now + 15min`；成功登录清零 |
| IP 白名单 | env CIDR 列表（空=不启用）；`X-Forwarded-For` 仅信任 Caddy（trusted proxy 显式配置） |
| 登录限流 | 10 req/min/IP，应用内令牌桶 |
| 注册 | **无注册端点**。`eterm create-user` CLI 创建（SSH 到 VPS 执行）；`ETERM_OPEN_REGISTRATION` 预留开关，默认关 |
| 暴露面 | 防火墙/安全组仅开 22（VPS 自身管理）+ 443（nginx）；eterm 监听 127.0.0.1:8220；MySQL 仅 127.0.0.1 |
| 审计事件 | login 成败 / device 创建吊销 / sync.push（按批次，不含数据）/ 设备管理操作 |
| 传输 | Caddy 终结 TLS（Let's Encrypt，HTTP-01）；eterm ↔ Caddy 走回环不加密 |

### 3.6 字段加密

- 主密钥：64B，env `ETERM_MASTER_KEY`（base64）。缺失即拒绝启动。**主密钥与 MySQL 备份分开保管**（密码管理器），备份泄露 ≠ 凭据泄露。
- 算法：AES-256-GCM，每字段随机 12B nonce；存储格式 `v1:` + base64(nonce ‖ ciphertext ‖ tag)。
- `v{n}` 前缀即密钥版本位：未来轮换时新写入用 `v2`，读时按前缀路由旧密钥，后台任务惰性重加密。
- 加密字段清单：`identities.password_enc`、`ssh_keys.private_enc/cert_enc/passphrase_enc`、`known_hosts.key_enc`。公钥、指纹、配置 JSON 不加密（非敏感且需可查询）。
- 实现为一对函数 `seal/open` + sqlc 自定义类型（`sql.Scanner` / `driver.Valuer`），业务层全程只见解密值。

### 3.7 配置、部署与运维

环境变量清单：

| 变量 | 必填 | 说明 |
|---|---|---|
| `ETERM_MASTER_KEY` | ✅ | base64 64B 主密钥 |
| `ETERM_DB_DSN` | ✅ | `user:pass@tcp(127.0.0.1:3306)/eterm?parseTime=true` |
| `ETERM_LISTEN` | — | 默认 `127.0.0.1:8080` |
| `ETERM_PEPPER` | ✅ | 口令 pepper，随机 ≥32B |
| `ETERM_IP_WHITELIST` | — | 逗号分隔 CIDR，空=不启用 |
| `ETERM_TLS_TRUSTED_PROXY` | — | Caddy 所在回环，默认 `127.0.0.1` |

部署件（`deploy/` 目录）：
- `Caddyfile`：`eterm.example.com { reverse_proxy 127.0.0.1:8080 }`（自动 HTTPS）
- `eterm.service`：systemd unit，`Restart=always`，`EnvironmentFile=/etc/eterm.env`（0600 权限）
- `backup.sh`：mysqldump 单事务快照 + 异地同步（cron 每日）；主密钥不在备份内
- 健康检查：`GET /healthz`（无认证，仅返回 ok + 版本）；Prometheus metrics 端点 P2 再加

升级流程：scp 新二进制 → `eterm migrate` → systemd 重启；迁移必须向后兼容一个版本（支持回滚）。

**实际部署记录（2026-11-14，M0 出口）**：`https://hub.example.com`（Let's Encrypt，nginx 终结 TLS + WS 升级头，配置归档于 `deploy/nginx-example.conf`）→ 反代 `127.0.0.1:8220`；eterm 原生 TLS（`ETERM_TLS_CERT/KEY`）保留为无反代场景备选，`Caddyfile` 保留为域名化替代方案。全链路实测通过：healthz / 登录 / `me`（真实 CA 链）、审计 IP 记录 XFF 真实来源、WebSocket wss 过 nginx 握手成功。DB 账号 `<db_user>@localhost`，密码仅存服务器本地受保护文件（0600，不入库）。

---

## 4. 客户端设计

### 4.1 工程结构

```
client/
├── app/                          # Flutter 工程
│   ├── lib/
│   │   ├── main.dart
│   │   ├── features/
│   │   │   ├── auth/             # 登录、引导
│   │   │   ├── hosts/            # 组树 + 标签过滤 + 搜索 + 详情表单
│   │   │   ├── terminal/         # 终端页、会话管理
│   │   │   ├── keychain/         # Keys / Identities / KnownHosts
│   │   │   ├── sftp/             # 双面板、传输队列
│   │   │   ├── portfw/           # 转发规则
│   │   │   └── settings/         # 设备管理、同步状态、主题
│   │   ├── data/                 # Rust bridge 的 Dart 封装（repository 层）
│   │   └── ui/                   # 主题、通用组件
│   ├── macos/  android/          # 平台壳
│   └── pubspec.yaml
├── rust_core/
│   ├── src/
│   │   ├── api/                  # frb 导出面（见 §4.4）
│   │   ├── store/                # rusqlite、实体仓库、同步状态标记
│   │   ├── sync/                 # pull/push、cursor、LWW 合并、退避
│   │   ├── ssh/                  # 会话池、认证、跳板、代理、转发
│   │   ├── sftp/
│   │   ├── keygen/
│   │   └── util/                 # 字段加密、环形缓冲
│   └── Cargo.toml
└── rust_builder/                 # frb cargokit（构建期编 Rust 入 app）
```

构建链：`flutter run/build` 经 rust_builder（cargokit）按目标平台编译 `rust_core`（macOS 静态库 lipo arm64+x86_64；Android 按 ABI 交叉编译），frb codegen 生成 Dart 绑定，CI 中 `cargo test` 与 `flutter test` 分阶段跑。

### 4.2 Rust core 模块设计

模块间依赖单向：`api → {sync, ssh, sftp, keygen} → store`。全部核心逻辑（除平台通道外）可在 macOS 上跑 `cargo test`。

**store/** — 本地 SQLite（表结构与 §3.2 同构，另加两张客户端私有表）：

```sql
sync_state (entity_type TEXT PK, dirty INT, last_error TEXT, updated_at)
outbox     (id INTEGER PK, entity_type, entity_id, op, payload_json, attempts, next_retry_at)
```

写路径：UI 变更 → **先写本地库**（立即生效，离线可用）→ 写 outbox → sync 引擎择机 push → 成功后以服务端 `rev` 回填本地行。读路径：UI 永远只读本地库。

**sync/** — 实现 §3.4 状态机。要点：
- HTTP 客户端 `reqwest`（rustls TLS，不用系统 OpenSSL）。
- 退避：1s/2s/4s/…/上限 60s；WS 断线由 sync 引擎统一管理重连。
- LWW 合并：冲突时按字段比较 `updated_at`，合并结果重推；`ssh_key` 类型永不合并内容，只处理版本指针（§3.2 不可变版本化）。

**ssh/** — russh 会话管理：
- `SessionPool`：`HashMap<SessionId, SshSession>`；SessionId 由 Dart 侧持有。
- 认证链：按 Identity 组合 password / key / key+cert；私钥从 store 解密载入内存，会话结束即弃。
- 跳板链（§4.6）、SOCKS5/HTTP 代理（连接前置）、keepalive（interval 15s）。
- 端口转发监听由 tokio 任务承载（§4.6）。
- Shell Integration 探测（PRD F12.2）：独立短连接执行探测命令取 cwd/历史钩子，三态 `auto/on/off`，失败降级不影响主会话；历史记录本地库存储（跨端同步为 P2）。

**keygen/** — Ed25519 / ECDSA P-256 / RSA(3072) 生成；OpenSSH 格式 PEM 导入导出（`russh-keys`）；指纹计算（SHA256:base64）。FIDO2/生物识别为 P2，接口位预留 `origin` 字段（与 §3.2 对齐）。

### 4.3 本地存储与密钥保管

- **本地库主密钥（LKMK）**：首次启动生成 32B 随机数，存 `flutter_secure_storage`（macOS → Keychain；Android → Keystore）。此后启动时经 FFI 传入 Rust 初始化 store。
- Rust 侧不直接调用平台钥匙串 API（避免 JNI/Security.framework 的双份绑定代码），**密钥获取统一走 Flutter 平台通道**——平台面收窄为一个接口。
- 本地库敏感字段用 LKMK 做 AES-256-GCM 字段加密（与服务端同款 seal/open），**不引入 SQLCipher**（license 与编译链负担）。
- 凭据内存纪律：解密后的私钥仅存在于使用瞬间；`Drop` 时显式 `zeroize`（`zeroize` crate）。日志层全局禁止输出 `*_enc` 解密结果与 token（`tracing` + 脱敏 filter，正则同 PRD F10.3）。

### 4.4 FFI 边界（frb 导出面）

导出 API 分四组（示意签名，Dart 侧生成对应强类型）：

```rust
// —— vault / 同步 ——
fn init_store(db_path: String, lkmk: Vec<u8>) -> Result<VaultInfo>;
fn sync_start(cfg: SyncConfig) -> Stream<SyncEvent>;      // 状态机事件流
fn sync_stop();
fn list_hosts(filter: HostFilter) -> Vec<HostNode>;        // 含组树展开
fn upsert_host(host: HostDraft) -> Result<Uuid>;           // 写本地 + outbox
fn delete_entity(kind: EntityKind, id: Uuid) -> Result<()>;

// —— 终端会话 ——
fn ssh_connect(spec: ConnectSpec) -> impl Future<SessionId>;  // 含跳板链解析
fn ssh_write(session: SessionId, data: Vec<u8>);
fn ssh_resize(session: SessionId, cols: u32, rows: u32);
fn ssh_close(session: SessionId);
fn ssh_output(session: SessionId) -> Stream<SessionFrame>;    // {kind: output|exit|error}
fn ssh_status(session: SessionId) -> Stream<ConnState>;       // 三态灯数据源

// —— sftp ——
fn sftp_list(session: SessionId, path: String) -> impl Future<Vec<FileEntry>>;
fn sftp_transfer(job: TransferJob) -> Stream<TransferProgress>;  // 含 cancel 控制
fn sftp_cancel(job_id: Uuid);

// —— keychain ——
fn key_generate(kind: KeyKind, passphrase: Option<String>) -> impl Future<Uuid>;
fn key_import(openssh_pem: String) -> Result<Uuid>;
fn key_export(id: Uuid) -> impl Future<String>;            // 需 UI 二次确认后调用
fn key_deploy_public(host: Uuid, key: Uuid, path: Option<String>) -> impl Future<()>;
```

设计约束：
- **流式边界只用于三类高频数据**：终端输出、传输进度、同步事件；其余全部请求-响应。
- 终端输出帧经 `Stream<Vec<u8>>` 跨 FFI；Rust 侧每会话维护 1MB 环形缓冲作为背压上限——渲染消费不及则滚动丢弃最旧数据（PRD §2.4 v1 遗产，语义保留在客户端）。
- 错误统一为 `EtermError{code, message, entity?}`，Dart 侧映射为异常/UiState，FFI 边界不 panic（`catch_unwind` 兜底）。

### 4.5 终端实现

数据流：

```
russh Channel ──► tokio task: 解析 SSH 消息 ──► mpsc channel
      ──► frb Stream<Uint8List> ──► Dart Isolate
      ──► TerminalBackend.write ──► xterm.dart 渲染（WebGL/Canvas 自适应）
```

- 输入：xterm.dart `onInput` → `ssh_write`；粘贴走 Bracketed Paste；OSC 52 剪贴板双向接入系统剪贴板。
- **IME（M0 spike 焦点）**：自定义 `InputHandler` 接住 composing 事件，提交（commit）整段送入终端；验证拼音/日文连续输入与退格在 composing 期间的行为。不达标则切换备选：平台原生输入视图 overlay + 手动合成（预案 B，工作量 +1 周）。
- resize：UI 尺寸变化 → 计算 cols/rows → `ssh_resize` → 远端 `SIGWINCH`。
- 断线重连（PRD F3.4）：keepalive 15s×3 无响应判死 → 指数退避自动重建会话（复用 ConnectSpec）→ UI 顶部横幅提示"已重建，远端断线期间输出不可恢复"（不虚构 tmux 能力，Startup Command 模板内置 `tmux attach` 建议）。环形缓冲保留断线前输出供回看，不重放进新会话。
- 会话三态灯：`ConnState` 流驱动（🟢 output 计数增量 / 🟡 检测到口令提示 pattern（与日志脱敏共用规则表）/ 🔴 exit|error）。

### 4.6 SFTP、端口转发、跳板链

**SFTP**：russh channel 开 `sftp` 子系统。传输队列：分块 32KB、并发 8 管道；断点续传按远端文件当前 size 起始 append；冲突策略（skip/overwrite/rename）在任务入队时声明。进度经 `Stream<TransferProgress>` 上报。远端编辑（PRD F6.3）：下载至本地临时目录 → 打开编辑器 → watcher 检测变更 → 弹提示回传。

**端口转发**（客户端本地监听，PRD F7）：
- Local：tokio `TcpListener` 绑 `bind_addr` → 每 accept 一个连接开一条 `direct-tcpip` channel。
- Remote：SSH 层请求 `tcpip-forward`，远端 open `forwarded-tcpip` channel → 客户端 dial `remote_host:port`。**russh 对 remote forward 的 client 侧支持列入 M0 spike 项**；若缺失，M2 前自行实现 channel open 处理（工作量可控）。
- Dynamic：内置最小 SOCKS5 服务（CONNECT only，~300 行）→ 逐连接 `direct-tcpip`。
- 启停即规则 `enabled` 翻转；监听前端口占用预检；规则数据全走同步（多端一致）。

**跳板链**：`ConnectSpec.hops: [HostId]`；逐跳建立连接，第 N 跳的 channel 经 `russh` 的 `connect_stream` 作为第 N+1 跳的底层 TCP 流（ProxyJump 语义）。组级跳板链由 Host 解析继承链时展开。

### 4.7 Flutter UI 层

| 页面 | 要点 |
|---|---|
| 登录/引导 | 首启流程：输入中枢地址 + 用户名口令 → 设备命名 → 登录并全量同步 |
| Host 列表 | 组树折叠 + 多标签 AND 过滤 + 搜索；500+ 行虚拟滚动（`ListView.builder` + 组扁平化）；长按右键菜单（桌面右键 / 移动长按） |
| 终端页 | 单会话为主视图；Tab 栏多会话（M2）；分屏（M4）；三态灯显示于 Tab/侧栏 |
| Keychain | 三 Tab（Keys/Identities/KnownHosts）；部署公钥向导；导出强制二次确认 |
| SFTP | 双面板（本地 = 设备文件系统）；桌面拖拽 + 移动选择式；传输队列抽屉 |
| 设置 | 设备管理（列表/吊销）、同步状态（cursor 落后量、outbox 积压）、主题、脱敏规则编辑 |

状态管理约定：Rust 是唯一事实源（本地库），Dart 层 riverpod 仅做投影——`SyncEvent` / 查询结果流 → `AsyncNotifier`，UI 不直接持有业务数据副本。路由 `go_router`；主题含终端配色方案（继承组设置 `terminal_theme`）。

### 4.8 Android 专项

- 键盘附加条：常驻软键盘上方，4 键 × N 组可重排（Esc/Tab/Ctrl/方向/自定义串），数据存本地设置（不同步，设备私有）。
- 手势：单指滑动手势区 → 方向键连续触发（三档速度）；双击 = Tab；双指捏合 = 字号。
- 后台存活：连接期间前台服务 + 常驻通知（Android 8+）；**不承诺后台长连**（与 Termius 同口径）。
- 返回键：终端页拦截为 Esc / 二次退出。
- 权限：存储（SFTP 本地侧走 SAF 而非全盘权限）、通知（前台服务）。目标 API 35。

---

## 5. 关键流程时序

### 5.1 首次登录与全量同步

```
Dart UI ─ login(addr, user, pass, device_name)
  → Rust sync: POST /auth/login → token 入 flutter_secure_storage
  → init_store 若空库: cursor=0 循环 pull 直至追平（凭据字段收到即 LKMK 加密落库）
  → 打开 WSS 订阅通知 → SyncEvent::Ready → UI 进主界面
失败路径: 401 → 提示重试；429 → 提示锁定；网络不可达 → 允许进入离线模式（无数据时仅引导重试）
```

### 5.2 日常增量同步

```
A 设备改 Host → 本地库写 + outbox → push → 服务端 rev=42 → WS 推 {rev:42}
B 设备收到 WS → pull(cursor=41) → 应用变更 → riverpod 投影刷新 → UI 秒级可见
```

### 5.3 离线创建与收敛

```
飞行模式: 新建 Host(id=UUIDv7 本地生成) → 本地立即可连该主机（数据面不依赖中枢）
恢复联网: outbox 重试 → push(base_rev=0, 新建) → 服务端分配 rev → 其他设备收敛
并发同名编辑: push 冲突 → LWW 字段级合并 → 重推成功；审计留痕
```

---

## 6. 安全设计

### 6.1 威胁模型（公网 VPS 部署）

| 资产 | 威胁 | 缓解 |
|---|---|---|
| 公网 API | 爆破 / 注入 / 越权 | Argon2id + 失败锁定 + 限流 + IP 白名单；sqlc 参数化；vault 维度鉴权（token ↔ user ↔ vault 归属校验） |
| MySQL | 备份/磁盘被盗 | `*_enc` 字段 AES-GCM（主密钥独立保管）；MySQL 仅 127.0.0.1 |
| VPS 整机被入侵 | 主密钥 + DB 同失 → 凭据全泄 | **已知接受的风险**（PRD §2.2 拍板）；缓解：最小暴露面、systemd 非特权用户运行、无 shell 常驻 |
| 客户端设备失窃 | token + 本地库被取 | OS 钥匙串 + LKMK 字段加密；**设备吊销**即时断同步（PRD §7）；P2：远程擦除指令 |
| 传输链路 | MITM | Let's Encrypt 正常 CA 链校验，无自签例外；WSS 同链路 |
| 客户端日志/内存 | 凭据落日志 | 全链路脱敏 filter + `zeroize`；会话日志口令提示不记录（PRD F10.3） |

### 6.2 凭据生命周期

```
生成/导入(客户端 keygen) → 加密上传(同步面, AES-GCM@服务端落盘)
  → 同步下发(TLS 内解密语义) → 客户端 LKMK 加密落本地库
  → 使用(ssh 会话内存, 用毕 zeroize)
  → 轮换(ssh_keys 新版本行 + superseded_by, 引用方更新)
  → 吊销(软删 tombstone, 客户端解除引用; 审计记录)
```

### 6.3 敏感规则表（单一来源，两端共用语义）

默认正则（可编辑，存 vault 设置同步）：`password\s*[=:]\s*\S+`、`token`、`AKIA[0-9A-Z]{16}`、`-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`。用途两处：会话日志脱敏（写前过滤）、AI 上下文过滤（P2）；口令提示检测（不回显 pattern：`password:`/`sudo`/`passphrase`）同时驱动 🟡 状态灯与日志跳过。

---

## 7. 测试策略

| 层 | 手段 | 关键用例 |
|---|---|---|
| 服务端单元 | go test | Argon2id 参数、seal/open 往返、校验钩子 |
| 服务端集成 | go test + testcontainers-go（真实 MySQL） | login/锁定、pull 分页边界、push 冲突→LWW→重推收敛、tombstone |
| **同步协议一致性** | 模拟客户端×2 交叉随机操作 N 轮 → 断言两端最终一致且 cursor 连续 | 幂等、乱序、重放、tombstone、密钥版本链 |
| Rust core 单元 | cargo test | store 写路径 + outbox、LWW 合并、环形缓冲丢弃策略 |
| SSH 集成 | cargo test + docker openssh-server | 口令/密钥/证书认证、跳板两跳、local/remote/dynamic 转发、keepalive 断连重建 |
| Flutter | widget test | 登录流、列表过滤、终端页接 mock stream |
| 端到端 | Makefile `e2e` 脚本：起中枢(docker) + 桌面客户端 headless 冒烟 | 注册→同步→连接→SFTP 上传→双端收敛 |
| 上线前回归 | 真实含 sudo / AWS key 的会话验证日志零明文（PRD 风险表项） | 脱敏规则生效 |

---

## 8. M0 Spike 清单（含触发复议条件）

| # | Spike | 通过标准 | 失败预案 |
|---|---|---|---|
| S1 | Flutter 终端 IME | xterm.dart + 自定义 InputHandler：拼音连续 composing、退格、候选上屏、中日韩混输正确；`top` 渲染 30min 无明显掉帧。**✅ 已通过（2026-11-14）**：composing/候选/混输原生可用；过程中暴露并修复上游两缺陷（DEL 当可打印、光标无宽字符感知），vendor fork `4.0.0-eterm.1` + 5 项回归测试 | 预案 B：原生输入 overlay（+1 周）；仍不行 → 技术栈复议（Tauri 路线） |
| S2 | russh 长会话 | `tail -f` 高吞吐 30min 稳定、内存无泄漏；keepalive 断网 10s 自动重建成功。**✅ 已通过（2026-11-14）**：soak 工具五阶段全绿——connect+公钥认证、回环吞吐（上行 cat>/dev/null 1MB 块 / 下行 dd）、持续输出（urandom）、keepalive 静默长会话（定期探活）、断线重连全新握手。工具存档 `client/spikes/s2_russh`（`soak --host --port --user --key`） | 换 `openssh` 进程兜底（仅桌面）；移动端再评估 |
| S3 | frb 双端编译 | 同一 rust_core 产出 macOS(arm64) 与 Android(arm64-v8a) 可用绑定，流式接口延迟 < 5ms/帧。**⏳ macOS ✅（2026-11-14）**：StreamSink 流模式实测 2.506ms/帧（64KB 帧），UTF-8 字节边界集成测试通过；frb v2.13 踩坑记录：`rust_input: crate::api` 新语法、impl Stream 不支持（改 StreamSink 参数模式）、crate 名须 `rust_lib_eterm`。**Android 构建链验证中**（磁盘满事故 + Gradle 守护进程缓存污染，已定位修复路径） | 降级方案：平台通道手写桥（仅限问题接口） |
| S4 | russh remote forward | client 侧能处理 `forwarded-tcpip` channel open | 自实现（M2 前完成，工作量 +3~5 天） |
| S5 | OpenSSH 证书认证 | russh-keys 加载 `id_ed25519-cert` + CA 验证通过。**✅ 已通过（2026-11-14）**：生产服务器实测——ed25519 CA + 用户证书（principal root），russh `authenticate_openssh_cert` → 真实 sshd（临时 drop-in `TrustedUserCAKeys`，测毕即删无残留），`whoami=root` 返回正确。`soak --cert` 用法（文档注释里的 `--cert-mode` 未实现） | 短期降级纯密钥认证，证书列 P1 补 |

S1–S3 为 M0 门禁（PRD §6），任一失败先走预案，预案也不可行即召开技术栈复议。

---

## 9. 里程碑任务分解

**M0（2~3 周）**：S1–S5 spike（W1，与下并行）→ 服务端：migrations 全量 + auth/device + pull/push/ws（W1–W2）→ 客户端：frb 骨架 + store/sync 引擎 + 登录页 + Host 列表 + 终端页（W2–W3）→ 公网部署（Caddy/systemd/防火墙/备份）+ 双端验收（W3）。出口：PRD §6 M0 标准（含"停中枢仍可连"）。

**M1（2 周）**：Android 壳（键盘附加条/手势/前台服务）+ Keychain 全量（keygen/import/export/部署公钥/KnownHosts 确认）+ SFTP 基础双面板。出口：手机免密直连。

**M2（2~3 周）**：跳板链 + 代理 + Agent Forwarding + 端口转发三类 + Group 继承完整化 + Tags/搜索 + 会话日志（本地）。出口：Termius 逐项核对（用调研报告 §九反向验证），可停订。

**M3（2 周）**：导入导出（`ioconv/`：ssh_config/CSV 解析 + JSON/YAML/ssh_config 导出）+ 环境变量 + Autocomplete 与 Shell Integration（三态降级，依赖 S1 的 IME 成果）+ Passkey/WebAuthn + 脱敏回归。出口：Termius 真实数据迁入完成切换。

**M4（持续）**：Workspaces/分屏广播、iOS 壳、AI BYOK、审计报表、团队 Vault、FIDO2/生物识别、metrics。

---

## 10. 风险登记册（技术视角）

| 风险 | 概率 | 影响 | 缓解 / 触发点 |
|---|---|---|---|
| xterm.dart IME 缺陷 | 中 | 高 | S1 前置；预案 B 预留 1 周 |
| russh 能力缺口（证书/remote forward） | 中 | 中 | S4/S5 前置；均已知降级路径 |
| frb 版本升级破坏面 | 中 | 中 | frb 绑定生成物入库 + 升级走独立 PR；`api/` 门面收窄变更面 |
| 同步收敛缺陷 | 低 | 高 | §7 一致性模糊测试作为 CI 门禁 |
| 公网 API 新暴露面 | 低 | 高 | §6.1 缓解集 + 上线 checklist（防火墙/白名单/备份验证） |
| Android 构建链（cargokit NDK）复杂度 | 中 | 低 | M0 S3 就验证；CI 缓存 NDK 工具链 |
| 单人维护带宽 | 高 | 中 | 里程碑按可停订收口；M2 后功能冻结（PRD §8） |

