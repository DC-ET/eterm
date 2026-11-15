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
