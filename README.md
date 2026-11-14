# eterm

自托管的主机与凭据数据中枢 + 多端客户端。服务器信息与密钥在自有服务器的 MySQL 中唯一统一管理；客户端（Mac / Android）同步后**以其所在本地网络直连目标服务器**，中枢不出现在数据面上。

- 产品定义：[docs/eterm-产品设计与需求文档-v2.md](docs/eterm-产品设计与需求文档-v2.md)
- 技术方案：[docs/plan/eterm-技术方案.md](docs/plan/eterm-技术方案.md)

## 仓库结构

```
server/    Go 中枢（单二进制 + MySQL）
client/    Flutter + Rust core（M0 起步）
deploy/    Caddyfile / systemd / 备份脚本
docs/      PRD 与技术方案
```

## 本地开发

```bash
# 服务端（需本地 MySQL；root 免密示例见 Makefile）
make test     # 单测 + 集成测试（ETERM_TEST_DSN 注入 eterm_test 库）
make build    # 产出 server/bin/eterm
make migrate  # 对开发库 eterm 执行迁移
make run      # 本地启动（临时生成密钥，仅开发用）

# 创建管理员（交互式）
cd server && ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
  ETERM_PEPPER=$(openssl rand -hex 32) ./bin/eterm create-user

# Rust core
cd client/rust_core && cargo test
```

## 部署（公网 VPS）

见 [deploy/](deploy/)：Caddyfile（唯一 443 暴露面，自动 TLS）+ systemd + 每日备份。
安全基线（M0 即公网）：失败锁定、登录限流、IP 白名单、最小端口暴露、MySQL 仅本机监听。

## 当前状态

M0 进行中——服务端骨架完成（认证/设备/同步协议/WS/加密，测试全绿）；
客户端 rust_core 骨架就绪，Flutter 安装后进入 spike S1–S5（见技术方案 §8）。
