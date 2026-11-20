# eterm 发布流程

## Android 安装包

### 约定（2026-11-15 起）

- **上传位置**：服务器 `120.26.109.221:/opt/mao-data/uploads/eterm/`
- **常规更新**：每次**覆盖**同一个文件 `eterm-android.apk`（避免占满服务器磁盘，当前磁盘余量 ~7G）
- **大版本更新**：另存一份带版本号的副本 `eterm-android-vX.Y.Z.apk`（pubspec 的 version 前两段变化时视为大版本，人工判断）
- 产物为 release 签名（debug key，直接可装）；三 ABI 合一（arm64/armv7/x86_64）

### 一条命令发布

```bash
client/app/scripts/release_android.sh              # 构建 + 覆盖上传 + 校验
client/app/scripts/release_android.sh --versioned  # 大版本：额外保留 vX.Y.Z 副本
```

脚本内部：flutter build apk --release → scp 覆盖上传 → sha256 双端校验。
SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。

### 手动流程（等价）

```bash
cd client/app
flutter build apk --release                       # 产物 build/app/outputs/flutter-apk/app-release.apk
scp -i ~/Downloads/_my-aliyun-ecs-2026.pem \
  build/app/outputs/flutter-apk/app-release.apk \
  root@120.26.109.221:/opt/mao-data/uploads/eterm/eterm-android.apk
```

### 手机安装

apk 传到手机（微信文件传输助手 / 网盘 / USB 拷贝）→ 点开安装（允许"未知来源"）→ 覆盖安装无需卸载旧版。

### 发布前自检清单

- [ ] `flutter analyze` 无问题、`cargo test --lib`（client/app/rust）全绿
- [ ] 主清单含 `INTERNET` 权限（历史教训：缺它 release 真机 `Failed host lookup`）
- [ ] 登录/同步/连接一轮通过（guitest 测试账号或自有账号）
- [ ] 服务端 `eterm` 服务正常（`systemctl is-active eterm`）

## 服务端部署（Node/TS）

### 生产形态

- systemd 单元 `/etc/systemd/system/eterm.service`：以用户 `eterm` 跑
  `/usr/local/eterm-node/bin/node node_modules/tsx/dist/cli.mjs src/main.ts serve`，
  工作目录 `/opt/eterm`，环境文件 `/etc/eterm.env`（0600）
- **`/opt/eterm` 不是 git 仓库**，源码靠 rsync 同步；`node_modules` 已在服务器上
- `/usr/local/bin/eterm` 是 Go 时代遗留静态二进制，**不在服务链路上**（别被它迷惑）
- `serve` 启动时会自动跑迁移（`main.ts` 调 `runMigrations`），并把 goose 时代的
  `goose_db_version` 收编为基线，不会重放 DDL；监听端口以 `/etc/eterm.env` 的
  `ETERM_LISTEN` 为准（生产 8220，前面挡 nginx）

### 发布前自检（server/ 下）

- [ ] `npm run typecheck`
- [ ] `npm test` —— **必须配本地 MySQL**：
      `ETERM_TEST_DSN='root@tcp(127.0.0.1:3306)/mysql?parseTime=true' npm test`（27 个）
      不设 DSN 时 api/sync/code-review 三个套件会报 `ETERM_TEST_DSN 未设置`而失败，
      那是环境未配，不是代码回归

### 一条命令部署

```bash
server/scripts/deploy.sh            # 备份 → rsync src+migrations → 改属主 → 重启 → 探针验证
```

脚本内部等价于：

```bash
# 1. 备份（回滚用）
ssh root@120.26.109.221 'tar czf /opt/eterm-src-backup-$(date +%Y%m%d).tgz -C /opt/eterm src migrations'
# 2. 同步源码（package.json/lock 有变更时才需要在服务器 npm ci）
rsync -rlptD --delete -e "ssh -i $ETERM_SSH_KEY" server/src/       root@120.26.109.221:/opt/eterm/src/
rsync -rlptD --delete -e "ssh -i $ETERM_SSH_KEY" server/migrations/ root@120.26.109.221:/opt/eterm/migrations/
# 3. 属主（服务用户）+ 重启
ssh root@120.26.109.221 'chown -R eterm:eterm /opt/eterm/src /opt/eterm/migrations && systemctl restart eterm'
```

SSH 密钥默认 `~/Downloads/_my-aliyun-ecs-2026.pem`，可用 `ETERM_SSH_KEY` 覆盖。

### 部署后验证

- [ ] `systemctl is-active eterm` → `active`
- [ ] `curl https://eterm.etarch.cn/healthz` → `{"status":"ok","version":"0.1.0-ts"}`
      （版本号是源码硬编码，**不能用来判断新旧**）
- [ ] 新路由探针：`curl -o /dev/null -w '%{http_code}' -X POST https://eterm.etarch.cn/api/v1/auth/password`
      → **401 = 路由已上线**；404 = 部署的还是旧代码
- [ ] `journalctl -u eterm --since "3 min ago"` 无异常（迁移/数据库就绪/listen）

### 回滚

```bash
ssh root@120.26.109.221 'cd /opt/eterm && tar xzf /opt/eterm-src-backup-<日期>.tgz \
  && chown -R eterm:eterm src migrations && systemctl restart eterm'
```

### 历史教训

- 2026-11-20：生产 `/opt/eterm/src` 停留在 TS 重写当天（11-14），之后三个 commit
  （P0 跨 vault 安全修复、Snippets 下线、修改密码）均未部署，客户端改密码 404。
  **每次服务端 commit 后都要跑部署**，不要等客户端报障才发现。
