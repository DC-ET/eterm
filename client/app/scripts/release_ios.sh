#!/usr/bin/env bash
# eterm iOS 发布：前置校验 → bump build 号 → 构建 ipa → 上传 TestFlight → 提交 bump。
# 约定见 docs/eterm-发布流程.md（iOS 小节）与 docs/plan/eterm-iOS客户端技术方案.md §5/§6：
#   - pubspec.yaml 是 build 号唯一事实源；TestFlight 同 version 内 build 号须递增
#     （per-version，跨 version 可复用），沿用「工作区干净 + git pull --ff-only +
#     bump + 成功后 commit」不变式（与 release_android.sh §9.1 同构，防跨机撞号）
#   - 苹果托管分发：产物不经自有服务器，无元数据 JSON（磁盘紧张约定不适用，D11）
#   - --no-upload 本地演练：构建用 --no-codesign（免签名，只验证构建链），跳过上传/commit
#   - 上传凭据：ETERM_ASC_API_KEY / ETERM_ASC_API_ISSUER（App Store Connect → 集成 →
#     App Store Connect API 密钥；.p8 落 ~/.appstoreconnect/private_keys/）
set -euo pipefail
cd "$(dirname "$0")/.." # client/app

ASC_KEY="${ETERM_ASC_API_KEY:-}"
ASC_ISSUER="${ETERM_ASC_API_ISSUER:-}"
NO_UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --no-upload) NO_UPLOAD=1 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

# 0. 前置校验（§9.1 同构：bump 必须基于最新 pubspec）+ 上传通路就绪
if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ 工作区不干净，请先提交后再发布："
  git status --porcelain
  exit 1
fi
git pull --ff-only
if [[ "$NO_UPLOAD" == "0" ]]; then
  # 上传工具探测前置到 bump 之前：缺通路就别动 pubspec（否则留下未提交的孤儿 bump）
  if ! xcrun altool --help >/dev/null 2>&1; then
    echo "❌ xcrun altool 不可用（Xcode 26 可能已移除，见方案核验项 #13）。"
    echo "   兜底：Transporter.app 拖入 ipa 上传（GUI 一步），上传成功后手动 commit bump。"
    exit 1
  fi
  if [[ -z "$ASC_KEY" || -z "$ASC_ISSUER" ]]; then
    echo "❌ 缺上传凭据：请设置 ETERM_ASC_API_KEY / ETERM_ASC_API_ISSUER"
    echo "   （App Store Connect → 用户和访问 → 集成 → App Store Connect API 密钥，Admin 权限生成）"
    exit 1
  fi
fi

export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PATH="$HOME/development/flutter/bin:$PATH"

FV=$(flutter --version | sed -n '1p')
case "$FV" in
  *"3.50"*) ;;
  *) echo "❌ Flutter 版本须为 3.50.x（三端同主版本），当前: $FV"; exit 1 ;;
esac
echo "== $FV =="

# 1. bump pubspec build 号（+1，三端唯一事实源 §9.1）
source "$(dirname "$0")/lib_version.sh"
FULLVER=$(bump_build pubspec.yaml)
VER=${FULLVER%%+*}
BUILD=${FULLVER##*+}
echo "== bump build → $FULLVER =="

# 2. 构建
if [[ "$NO_UPLOAD" == "1" ]]; then
  # 演练模式：免签名构建（验证 cargokit/Xcode 构建链），不产出可上传的 ipa。
  # 演练 bump 无人消费：还原 pubspec 保持工作区干净，不卡下一次真发布（review P2#7）
  flutter build ios --release --no-codesign
  git checkout -- pubspec.yaml
  echo "== --no-upload 本地演练完成（构建链验证通过，bump 已还原，跳过签名 ipa 与上传）=="
  exit 0
fi

flutter build ipa --release
IPA=$(ls -t build/ios/ipa/*.ipa 2>/dev/null | head -1 || true)
if [[ ! -f "$IPA" ]]; then
  echo "❌ 构建产物缺失 build/ios/ipa/*.ipa"
  exit 1
fi
echo "== 产物 $IPA =="

# 3. 上传 TestFlight（受理成功 ≠ 处理完成：内部测试几分钟~半小时可见，
#    外部测试组每 version 首个 build 另需轻量 Beta 审核，方案 §5.2）
xcrun altool --upload-app --type ios -f "$IPA" \
  --apiKey "$ASC_KEY" --apiIssuer "$ASC_ISSUER"

# 4. bump 持久化：自动 commit+push（§9.1 不变式，防跨机撞号）
git add pubspec.yaml
git commit -m "release: ios $VER+${BUILD}（发布脚本自动 bump）"
git push

echo "✅ TestFlight 上传受理完成: $IPA ($VER+$BUILD)"
echo "   处理完成请到 App Store Connect 后台人工确认（一期不做 API 轮询）。"
