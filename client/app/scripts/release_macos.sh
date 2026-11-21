#!/usr/bin/env bash
# eterm macOS 发布：前置校验 → bump build 号 → 构建 → zip → generate_appcast（EdDSA）→ 覆盖上传 → 校验 → 提交 bump。
# 见 docs/plan/eterm-自动更新方案.md §9.2/§9.3：
#   - pubspec.yaml build 号唯一事实源；前置 clean + pull --ff-only；上传校验通过后 commit+push（§9.1）
#   - 磁盘紧张约定：覆盖同一文件 eterm-mac.zip / eterm-mac.xml，不新增版本副本
#   - --no-upload 本地演练；--notes=... 覆盖更新说明
set -euo pipefail
cd "$(dirname "$0")/.." # client/app

SERVER=root@120.26.109.221
KEY="${ETERM_SSH_KEY:-$HOME/Downloads/_my-aliyun-ecs-2026.pem}"
REMOTE_DIR=/opt/mao-data/uploads/eterm
ZIP=eterm-mac.zip
APPCAST=eterm-mac.xml
BASE_URL=https://eterm.etarch.cn/updates
SPARKLE_BIN=macos/Pods/Sparkle/bin
# EdDSA 私钥走文件不落钥匙串（§9.3，AGENTS.md 钥匙串教训同源）；ETERM_SPARKLE_PRIVATE_KEY 可覆盖
SPARKLE_KEY="${ETERM_SPARKLE_PRIVATE_KEY:-$HOME/Downloads/eterm-sparkle-ed25519}"

NOTES_ARG=""
NO_UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --no-upload) NO_UPLOAD=1 ;;
    --notes=*) NOTES_ARG="${arg#--notes=}" ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

# 0. 前置校验（§9.1）+ 工具链
if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ 工作区不干净，请先提交后再发布："
  git status --porcelain
  exit 1
fi
git pull --ff-only

export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH="$HOME/development/flutter/bin:$PATH"

FV=$(flutter --version | sed -n '1p')
case "$FV" in
  *"3.50"*) ;;
  *) echo "❌ Flutter 版本须为 3.50.x（与 Windows 端同主版本），当前: $FV"; exit 1 ;;
esac
echo "== $FV =="

# EdDSA 公钥必须已内嵌 Info.plist（占位符 = 旧客户端永远验证不了新包签名，§9.3）
PUBKEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' macos/Runner/Info.plist 2>/dev/null || true)
if [[ -z "$PUBKEY" || "$PUBKEY" == *NOT_SET* ]]; then
  echo "❌ Info.plist 的 SUPublicEDKey 仍是占位符：先跑 ${SPARKLE_BIN}/generate_keys -x \"$SPARKLE_KEY\"，"
  echo "   把 EdDSA 公钥写进 macos/Runner/Info.plist 的 SUPublicEDKey，再发布（§9.3）"
  exit 1
fi

# 1. bump pubspec build 号（+1，三端唯一事实源 §9.1；CFBundleVersion 随构建自动带上）
source "$(dirname "$0")/lib_version.sh"
FULLVER=$(bump_build pubspec.yaml)
VER=${FULLVER%%+*}
BUILD=${FULLVER##*+}
echo "== bump build → $FULLVER =="

# 2. 构建 + zip（ditto 保留资源 fork/xattr，Sparkle 官方口径 §9.2）
flutter build macos --release
APP=build/macos/Build/Products/Release/Eterm.app
if [[ ! -d "$APP" ]]; then
  echo "❌ 构建产物缺失 $APP"
  exit 1
fi
rm -f "build/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ZIP"
SUM=$(shasum -a 256 "build/$ZIP" | awk '{print $1}')
SIZE=$(stat -f%z "build/$ZIP")
echo "== sha256 ${SUM:0:16}… / ${SIZE} bytes =="

# 3. appcast：generate_appcast（暂存目录只放新 zip → 顺带不生成 delta，§13；私钥走文件 §9.3）
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "❌ 缺 $SPARKLE_BIN/generate_appcast（先跑一次 flutter build macos 让 pod install 拉 Sparkle）"
  exit 1
fi
if [[ ! -f "$SPARKLE_KEY" ]]; then
  echo "❌ EdDSA 私钥不存在: ${SPARKLE_KEY}（ETERM_SPARKLE_PRIVATE_KEY 可覆盖，§9.3；丢失=永远无法再发更新）"
  exit 1
fi
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "build/$ZIP" "$STAGE/$ZIP"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_KEY" \
  --download-url-prefix "$BASE_URL/" "$STAGE"
# Sparkle 2.9 的 generate_appcast 用归档名派生输出文件名（eterm-mac.zip → eterm-mac.xml），
# 不是固定的 appcast.xml；暂存目录只有本次产物，glob 取生成的 xml 即可
mv "$STAGE"/*.xml "build/$APPCAST"

# 3.5 注入 <description>（git log 标题；XML 转义交给 saxutils，手拼会翻车 §4.2）
NOTES="${NOTES_ARG:-$(git log -1 --pretty=%s)}"
python3 - "build/$APPCAST" "$NOTES" <<'PYEOF'
import sys
from xml.sax.saxutils import escape

path, notes = sys.argv[1], sys.argv[2]
if not notes.strip():
    sys.exit(0)
s = open(path, encoding="utf-8").read()
i = s.find("<item>")
if i < 0:
    sys.exit("appcast 无 <item>")
j = s.find("</title>", i)
if j < 0:
    sys.exit("appcast 无 <title>")
j += len("</title>")
s = s[:j] + "\n      <description>" + escape(notes) + "</description>" + s[j:]
open(path, "w", encoding="utf-8").write(s)
PYEOF
echo "== appcast 就绪（sparkle:version=${BUILD}）=="

if [[ "$NO_UPLOAD" == "1" ]]; then
  echo "== --no-upload 本地演练完成（bump 未提交，上传/回读已跳过）=="
  exit 0
fi

# 4. 上传（覆盖同一文件）
scp -i "$KEY" "build/$ZIP" "$SERVER:$REMOTE_DIR/$ZIP"
scp -i "$KEY" "build/$APPCAST" "$SERVER:$REMOTE_DIR/$APPCAST"

# 5. 校验：远端 sha256 一致 + 公网回读 appcast 校验 sparkle:version（走 Sparkle 真实请求路径）
REMOTE_SUM=$(ssh -i "$KEY" "$SERVER" "sha256sum $REMOTE_DIR/$ZIP" | awk '{print $1}')
if [[ "$SUM" != "$REMOTE_SUM" ]]; then
  echo "❌ 远端 sha256 不一致: $REMOTE_SUM / $SUM"
  exit 1
fi
REMOTE_XML=$(curl -fsS "$BASE_URL/$APPCAST")
if ! printf '%s' "$REMOTE_XML" | grep -q "<sparkle:version>${BUILD}</sparkle:version>"; then
  echo "❌ 公网回读 appcast 未含 sparkle:version=${BUILD}（nginx location 或元数据异常）"
  exit 1
fi

# 6. bump 持久化：自动 commit+push（§9.1 不变式，防跨机撞号）
git add pubspec.yaml
git commit -m "release: macos $VER+${BUILD}（发布脚本自动 bump）"
git push

echo "✅ 发布完成: $SERVER:$REMOTE_DIR/$ZIP + $APPCAST ($VER+$BUILD)"
