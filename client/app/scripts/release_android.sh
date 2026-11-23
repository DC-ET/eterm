#!/usr/bin/env bash
# eterm Android 发布：前置校验 → bump build 号 → 构建 → 生成更新元数据 → 覆盖上传 → 校验 → 提交 bump。
# 约定见 docs/eterm-发布流程.md 与 docs/plan/eterm-自动更新方案.md §9：
#   - pubspec.yaml 是 build 号唯一事实源；与 Windows 机异机发布，bump 必须基于最新 pubspec
#     （工作区干净 + git pull --ff-only），上传校验通过后自动 commit+push（防跨机撞号 §9.1）
#   - 常规更新覆盖同一文件 eterm-android.apk（磁盘紧张约定）；--versioned 另存副本
#   - --no-upload 本地演练：bump/构建/元数据齐全，跳过上传/回读/commit
set -euo pipefail
cd "$(dirname "$0")/.." # client/app

# 发布目标全部走环境变量（仓库内不落真实服务器/IP/域名；fork 部署自行导出）：
#   ETERM_SERVER / ETERM_SSH_KEY / ETERM_REMOTE_DIR / ETERM_UPDATE_BASE_URL
SERVER="${ETERM_SERVER:-root@YOUR_SERVER_IP}"
KEY="${ETERM_SSH_KEY:-$HOME/.ssh/your-server.pem}"
REMOTE_DIR="${ETERM_REMOTE_DIR:-/opt/mao-data/uploads/eterm}"
APK=eterm-android.apk
# 更新元数据基址：元数据 JSON 的下载地址与客户端 --dart-define 同源，必须显式提供
BASE_URL="${ETERM_UPDATE_BASE_URL:-}"

NOTES_ARG=""
VERSIONED=0
NO_UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --versioned) VERSIONED=1 ;;
    --no-upload) NO_UPLOAD=1 ;;
    --notes=*) NOTES_ARG="${arg#--notes=}" ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "❌ 必须导出 ETERM_UPDATE_BASE_URL（如 https://hub.example.com/updates）："
  echo "   更新元数据 JSON 的下载地址与客户端 --dart-define 都取自此值"
  exit 1
fi

# 0. 前置校验（§9.1：异机 bump 必须基于最新 pubspec，否则跨机撞号）
if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ 工作区不干净，请先提交后再发布："
  git status --porcelain
  exit 1
fi
git pull --ff-only

export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export JAVA_HOME="${JAVA_HOME:-/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$HOME/development/flutter/bin:$PATH"

FV=$(flutter --version | sed -n '1p')
case "$FV" in
  *"3.50"*) ;;
  *) echo "❌ Flutter 版本须为 3.50.x（与 Windows 端同主版本），当前: $FV"; exit 1 ;;
esac
echo "== $FV =="

# 1. bump pubspec build 号（+1，三端唯一事实源 §9.1）
source "$(dirname "$0")/lib_version.sh"
FULLVER=$(bump_build pubspec.yaml)
VER=${FULLVER%%+*}
BUILD=${FULLVER##*+}
echo "== bump build → $FULLVER =="

# 2. 构建（JAVA_HOME 钉 JDK17：GraalVM 的 jlink 过不了 AGP JdkImageTransform，见 AGENTS.md）
flutter build apk --release --dart-define=ETERM_UPDATE_BASE_URL="$BASE_URL"
ART=build/app/outputs/flutter-apk/app-release.apk
if [[ ! -f "$ART" ]]; then
  echo "❌ 构建产物缺失 $ART"
  exit 1
fi

# 3. 元数据 JSON（§4.1）：python3 json.dumps 序列化（提交标题常含中文引号，手拼必翻车）
SUM=$(shasum -a 256 "$ART" | awk '{print $1}')
SIZE=$(stat -f%z "$ART")
PUBLISHED=$(date +%Y-%m-%dT%H:%M:%S%z)
NOTES="${NOTES_ARG:-$(git log -1 --pretty=%s)}"
mkdir -p build
python3 - "$PWD/build/eterm-android.json" "$VER" "$BUILD" "$BASE_URL/$APK" "$SUM" "$SIZE" "$PUBLISHED" "$NOTES" <<'PYEOF'
import json
import sys

path, ver, build, url, sha, size, published, notes = sys.argv[1:9]
meta = {
    "version": ver,
    "build": int(build),
    "url": url,
    "sha256": sha,
    "size": int(size),
    "published_at": published,
    "notes": notes,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF
echo "== 生成 build/eterm-android.json（sha256 ${SUM:0:16}… / ${SIZE} bytes）=="

if [[ "$NO_UPLOAD" == "1" ]]; then
  echo "== --no-upload 本地演练完成（bump 未提交，上传/回读已跳过）=="
  exit 0
fi

# 4. 上传（覆盖同一文件；--versioned 另存带版本副本）
scp -i "$KEY" "$ART" "$SERVER:$REMOTE_DIR/$APK"
scp -i "$KEY" build/eterm-android.json "$SERVER:$REMOTE_DIR/eterm-android.json"
if [[ "$VERSIONED" == "1" ]]; then
  scp -i "$KEY" "$ART" "$SERVER:$REMOTE_DIR/eterm-android-v${VER}.apk"
  echo "== 已另存版本副本 eterm-android-v${VER}.apk =="
fi

# 5. 校验：远端 sha256 一致 + 公网回读 JSON（走客户端真实请求路径，顺带验证 nginx location）
REMOTE_SUM=$(ssh -i "$KEY" "$SERVER" "sha256sum $REMOTE_DIR/$APK" | awk '{print $1}')
if [[ "$SUM" != "$REMOTE_SUM" ]]; then
  echo "❌ 远端 sha256 不一致: $REMOTE_SUM / $SUM"
  exit 1
fi
REMOTE_META=$(curl -fsS "$BASE_URL/eterm-android.json")
REMOTE_VER=$(printf '%s' "$REMOTE_META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
REMOTE_BUILD=$(printf '%s' "$REMOTE_META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])')
if [[ "$REMOTE_VER" != "$VER" || "$REMOTE_BUILD" != "$BUILD" ]]; then
  echo "❌ 公网回读版本不一致: $REMOTE_VER+${REMOTE_BUILD}，期望 $VER+${BUILD}"
  exit 1
fi

# 6. bump 持久化：自动 commit+push（§9.1 不变式，防跨机撞号；只 bump 不 commit 等于没 bump）
git add pubspec.yaml
git commit -m "release: android $VER+${BUILD}（发布脚本自动 bump）"
git push

echo "✅ 发布完成: $SERVER:$REMOTE_DIR/$APK ($VER+$BUILD)"
