# eterm

自托管的主机与凭据数据中枢 + 多端客户端。服务器信息与密钥在自有服务器的 MySQL 中唯一统一管理；客户端（macOS / Android）同步后**以其所在本地网络直连目标服务器**，中枢不出现在数据面上。

- 产品定义：[docs/eterm-产品设计与需求文档-v2.md](docs/eterm-产品设计与需求文档-v2.md)
- 技术方案：[docs/plan/eterm-技术方案.md](docs/plan/eterm-技术方案.md)
- 发布流程：[docs/eterm-发布流程.md](docs/eterm-发布流程.md)

## 仓库结构

```
server/    中枢服务端（Node 22 + TypeScript + Fastify 5 + mysql2，tsx 直跑）
client/    Flutter 客户端 + Rust core（russh SSH 数据面 / rusqlite 本地库 / aes-gcm 字段加密）
deploy/    nginx 配置 / systemd 单元 / 备份脚本 / env 样例
docs/      PRD 与技术方案
```

## 本地开发

```bash
# 服务端（在 server/ 下；需本地 MySQL 与环境变量，样例见 deploy/eterm.env.example）
npm run typecheck   # tsc --noEmit
npm test            # vitest
npm run dev         # 本地启动
npm run migrate     # 执行迁移
npm run create-user # 创建用户（交互式）

# 顶层 make 接口（等价封装，见 Makefile）
make typecheck / test / run / migrate / create-user

# 客户端（在 client/app/ 下）
flutter analyze               # 必须 0 error
flutter build macos --debug   # 桌面构建
cd rust && cargo test --lib   # Rust core 测试
./scripts/release_android.sh  # Android APK 构建 + 覆盖上传（见 docs/eterm-发布流程.md）
```

## 部署（公网 VPS）

见 [deploy/](deploy/)：nginx 配置（唯一 443 暴露面，TLS 反代 127.0.0.1:8220）+ systemd 单元 + 每日备份。
安全基线：失败锁定、登录限流、最小端口暴露、MySQL 仅本机监听。

## 当前状态

M1 完成——服务端（认证/设备/同步协议/WS/静态加密）测试全绿并已部署生产；
客户端双端可用：登录 → 主机列表（分组/凭据状态）→ SSH 终端（PTY/多标签/断连重连）→
主机增删改 → 中枢增量同步；本地 sqlite + LKMK 字段加密 + 会话持久化（重启免登录），
私钥随中枢同步（跨设备可用）。进行中：Known Hosts 指纹校验、Keychain 密钥管理页、Logs。
