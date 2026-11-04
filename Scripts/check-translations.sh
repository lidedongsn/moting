#!/usr/bin/env bash
# 检查界面文案是否都有英文翻译：让编译器提取所有可本地化的字符串，和 Localizable.xcstrings 比对。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcodebuild -project App/Moting.xcodeproj -scheme Moting -configuration Debug -derivedDataPath .build/xcode \
  SWIFT_EMIT_LOC_STRINGS=YES build >/dev/null 2>&1 || { echo "编译失败" >&2; exit 1; }
python3 - <<'PY'
import glob, json, re, sys
keys = set()
for f in glob.glob(".build/xcode/Build/Intermediates.noindex/**/Debug/**/*.stringsdata", recursive=True):
    if re.search(r"/(GRDB|Atomics)\.build/", f):
        continue
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
keys.discard("")
have = json.load(open("App/Moting/Localizable.xcstrings"))["strings"]
missing = sorted(k for k in keys if "en" not in have.get(k, {}).get("localizations", {}))
stale = sorted(k for k in have if k not in keys)
for k in missing: print("缺翻译：", repr(k))
for k in stale: print("已不用：", repr(k))
print(f"共 {len(keys)} 条，缺 {len(missing)} 条，多余 {len(stale)} 条")
sys.exit(1 if missing else 0)
PY
