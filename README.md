# eterm

自托管的主机与凭据数据中枢 + 多端客户端。

服务器账号、密钥、主机信息集中在一台**你自己部署**的中枢里；各端客户端同步后，**以其所在本地网络直连目标服务器**——中枢只承载元数据同步，永远不出现在 SSH/SFTP 数据面上。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/DC-ET/eterm/actions/workflows/ci.yml/badge.svg)](https://github.com/DC-ET/eterm/actions/workflows/ci.yml)

## 架构

```
                ┌─────────────────────────────┐
                │  中枢（hub，自部署）          │
                │  Node + Fastify + MySQL     │
                │  元数据同步 / 认证 / 审计     │
                └──────────────┬──────────────┘
                               │ 同步面（HTTPS，仅元数据）
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   ┌────┴────┐            ┌────┴────┐            ┌────┴────┐
   │ macOS   │            │ Windows │  Android / iOS     │
   │ 客户端   │            │ 客户端   │            │ 客户端   │
   └────┬────┘            └────┬────┘            └────┬────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               │ 数据面（本地直连，SSH/SFTP 不出网）
                        ┌──────┴──────┐
                        │  目标服务器群 │
                        └─────────────┘
```

**两条铁律：**

1. **数据面直连**：终端、SFTP、端口转发全部由客户端（Rust core，russh）与目标服务器点对点完成。中枢宕机不影响已同步主机的连接，中枢也看不到任何会话内容。
2. **同步面最小化**：中枢只存元数据（实体 `data_enc` 静态加密 + 审计日志），凭据解密发生在客户端本地。

## 功能

- **多端**：macOS 桌面 / Windows 桌面 / Android / iPhone（同一 Flutter + Rust 代码库）
- **主机管理**：分组、增删改、凭据状态标识，中枢增量同步（cursor 循环，冲突按 `rev` 折叠）
- **SSH 终端**：PTY、多标签、断连重连、会话持久化（重启免登录）、端口转发
- **SFTP**：传输队列、`.eterm-part` 暂存 + 断点续传、取消/失败保留暂存
- **凭据与密钥**：口令 / 私钥托管，随中枢跨设备同步；Keychain（钥匙串）集成；本地生成 Ed25519/ECDSA/RSA 密钥
- **本地加密**：rusqlite 本地库 + LKMK 主密钥（`lkmk.bin`，0600）字段级 aes-gcm 加密
- **安全基线**：Argon2id 口令哈希（pepper 参与派生）、登录失败锁定与限流、设备 token 管理、审计日志、Known Hosts 指纹校验
- **自动更新**：三端共用检查/下载/校验逻辑（build 号唯一权威），macOS 走 Sparkle EdDSA 签名

## 快速开始

### 服务端（中枢）

```bash
cd server
# 必填环境变量（格式与生成命令见 deploy/eterm.env.example）
export ETERM_MASTER_KEY=$(openssl rand -base64 64)   # 解码后须 64 字节
export ETERM_PEPPER=$(openssl rand -hex 32)
export ETERM_DB_DSN='user:pass@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC'

npm ci
npm run migrate       # 执行迁移
npm run create-user   # 创建用户（交互式；--stdin-password 非交互）
npm run dev           # 本地启动
npm run typecheck && npm test
```

### 客户端

```bash
cd client/app
flutter pub get
cd rust && cargo test --lib && cd ..   # Rust core 测试
flutter analyze                        # 必须 0 error
flutter run                            # 选择 mac / windows / android / ios 设备
```

首次启动在登录页填入**你自己的中枢地址**（客户端不预填任何默认地址）。

## 仓库结构

```
server/          中枢服务端（Node 22 + TypeScript + Fastify 5 + mysql2）
  src/           serve / migrate / create-user；auth、syncstore、api、crypto
  migrations/    DDL 基线
client/app/      Flutter 客户端 + Rust core（frb 2.13 暴露）
  lib/           Dart UI / services（同步、更新、设置）
  rust/          russh SSH 数据面 / rusqlite 本地库 / aes-gcm / keychain
  scripts/       三端发布脚本（目标全部走环境变量，见下）
deploy/          nginx 样例 / systemd 单元 / 备份脚本 / env 样例
docs/            PRD、技术方案、发布流程
```

## 部署

生产部署参考 [deploy/](deploy/)：nginx 是唯一 443 暴露面（TLS 反代本机中枢），MySQL 仅本机监听，失败锁定 + 登录限流 + 每日备份。完整流程（含三端发布）见 [docs/eterm-发布流程.md](docs/eterm-发布流程.md)。

发布脚本不内置任何服务器信息，全部经环境变量注入：

```bash
export ETERM_SERVER=root@your-server-ip        # 或 user@host
export ETERM_SSH_KEY=~/.ssh/your-server.pem
export ETERM_REMOTE_DIR=/opt/mao-data/uploads/eterm
export ETERM_UPDATE_BASE_URL=https://your-hub.example.com/updates
export ETERM_SPARKLE_PRIVATE_KEY=~/.ssh/eterm-sparkle-ed25519   # 仅 mac 发布
```

客户端的应用内更新源同理：构建时 `--dart-define=ETERM_UPDATE_BASE_URL=...`，未注入 = 关闭更新检查。

## 开发门禁

提交前本地全绿；CI（GitHub Actions）对每个 push/PR 自动执行：

```bash
# server
npm run typecheck && npm test
# client
flutter analyze && flutter test
cd rust && cargo test --lib
# 密钥泄露扫描（全历史）
gitleaks detect
```

## 安全提示

- 本项目用于**自托管**场景。暴露到公网前请自行评估：TLS 证书、防火墙（仅 443 + SSH 管理口）、MySQL 绑定、备份加密。
- 中枢持有加密后的元数据，但**信任模型的核心是"中枢不在数据面上"**——请勿修改架构让中枢代联目标服务器。
- 发现安全问题请勿直接开 issue，先私下联系维护者。

## 文档

- [产品设计与需求文档](docs/eterm-产品设计与需求文档-v2.md)
- [技术方案](docs/plan/eterm-技术方案.md)
- [发布流程](docs/eterm-发布流程.md)
- [AGENTS.md](AGENTS.md)：面向 AI 协作代理的项目指令（踩坑记录与约定）

## License

[MIT](LICENSE)
