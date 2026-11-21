#!/usr/bin/env bash
# 共用 build 号递增 helper（自动更新方案 §9.1）：读 pubspec → 回写 N+1 → 回显 "X.Y.Z+N"。
# 被 release_android.sh / release_macos.sh source；Windows 侧 release_windows.ps1
# 无法 source bash，内嵌同语义 bump（正则口径一致）。
# 跨机不变式由调用脚本负责：bump 前工作区干净 + git pull --ff-only；
# 上传校验通过后自动 commit+push（防两台构建机撞号）。本文件纯 ASCII，兼容 bash 3.2。
# 口径备注：bash 版行尾 [[:space:]]* 会吞 \r（CRLF 工作副本被规整为 LF），
# ps1 版 [ \t]*$ 刻意不吞 \r（遇 CRLF 直接报错）。mac 端工作副本是 LF 时两者等价。
set -euo pipefail

# bump_build <pubspec路径> → stdout: X.Y.Z+N（已回写文件）
bump_build() {
  local pubspec="$1"
  local line ver build
  line=$(grep -E '^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+[[:space:]]*$' "$pubspec") || {
    echo "ERROR: pubspec version line not parseable: $pubspec" >&2
    return 1
  }
  ver=$(printf '%s' "$line" | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+[[:space:]]*$/\1/')
  build=$(printf '%s' "$line" | sed -E 's/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)[[:space:]]*$/\1/')
  build=$((build + 1))
  # 精确替换 version 行，不动其他行；-i.bak 兼容 BSD/GNU sed
  sed -i.bak -E "s/^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+[[:space:]]*\$/version: ${ver}+${build}/" "$pubspec"
  rm -f "${pubspec}.bak"
  printf '%s+%s\n' "$ver" "$build"
}
