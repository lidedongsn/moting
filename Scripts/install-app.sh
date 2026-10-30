#!/usr/bin/env bash
# 编译 Release 版并安装到 /Applications/Moting.app，安装后自动打开。
# 正在录音时不替换，避免打断会议。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Moting.app"
DB="$HOME/Library/Application Support/Moting/moting.sqlite"

if [ -f "$DB" ] && [ "$(sqlite3 "$DB" "select count(*) from meeting where status='recording'" 2>/dev/null || echo 0)" != "0" ]; then
  echo "正在录音，暂不安装。结束录音后再运行。" >&2
  exit 1
fi

cd "$ROOT/App"
xcodegen generate -q
xcodebuild -project Moting.xcodeproj -scheme Moting -configuration Release \
  -derivedDataPath "$ROOT/.build/xcode" build > "$ROOT/.build/install-build.log" 2>&1 || {
  grep -E "error:" "$ROOT/.build/install-build.log" | sort -u | head -20 >&2
  echo "编译失败，完整日志：$ROOT/.build/install-build.log" >&2
  exit 1
}
APP="$ROOT/.build/xcode/Build/Products/Release/Moting.app"

# 退出正在运行的 Moting（不论从哪里打开的）
if pgrep -x Moting > /dev/null; then
  osascript -e 'quit app "Moting"' > /dev/null 2>&1 || true
  for _ in $(seq 20); do pgrep -x Moting > /dev/null || break; sleep 0.3; done
  pkill -x Moting 2>/dev/null || true
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
# 让启动台 / Spotlight 立即看到新版本
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" > /dev/null 2>&1 || true
open "$DEST"
echo "已安装：${DEST}"
