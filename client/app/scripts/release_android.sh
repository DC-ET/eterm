#!/usr/bin/env bash
# eterm Android 发布：构建 release APK → 覆盖上传服务器 → 校验。
# 约定见 docs/eterm-发布流程.md：常规更新覆盖同一文件；大版本加 --versioned 另存副本。
set -euo pipefail
cd "$(dirname "$0")/.." # client/app

SERVER=root@120.26.109.221
KEY="${ETERM_SSH_KEY:-$HOME/Downloads/_my-aliyun-ecs-2026.pem}"
REMOTE_DIR=/opt/mao-data/uploads/eterm
APK=eterm-android.apk

export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export JAVA_HOME="${JAVA_HOME:-/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/development/flutter/bin:$PATH"

flutter build apk --release

ART=build/app/outputs/flutter-apk/app-release.apk
echo "== 上传 ${ART} → ${SERVER}:${REMOTE_DIR}/${APK} （覆盖）=="
scp -i "$KEY" "$ART" "$SERVER:$REMOTE_DIR/$APK"

# 大版本：手动传 --versioned 额外保留一份带版本号的副本
if [[ "${1:-}" == "--versioned" ]]; then
  VER=$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
  scp -i "$KEY" "$ART" "$SERVER:$REMOTE_DIR/eterm-android-v$VER.apk"
  echo "== 已另存版本副本 eterm-android-v$VER.apk =="
fi

LOCAL_SUM=$(shasum -a 256 "$ART" | cut -c1-16)
REMOTE_SUM=$(ssh -i "$KEY" "$SERVER" "sha256sum $REMOTE_DIR/$APK" | cut -c1-16)
echo "== 校验：本地 $LOCAL_SUM / 远端 $REMOTE_SUM =="
if [[ "$LOCAL_SUM" == "$REMOTE_SUM" ]]; then
  echo "✅ 发布完成：$SERVER:$REMOTE_DIR/$APK"
else
  echo "❌ 校验不一致"; exit 1
fi
