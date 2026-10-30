#!/usr/bin/env bash
# 下载 sherpa-onnx 静态库与 C 接口头文件，合并为 Vendor/CSherpaOnnx.xcframework（不入库）
set -euo pipefail

VERSION=1.13.8
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/CSherpaOnnx.xcframework"

if [ -d "$OUT" ]; then
  echo "已存在：$OUT"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

NAME="sherpa-onnx-v${VERSION}-osx-arm64-static-no-tts-lib"
curl -fL --retry 3 -o lib.tar.bz2 \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
tar xjf lib.tar.bz2

mkdir include
curl -fL --retry 3 -o include/c-api.h \
  "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VERSION}/sherpa-onnx/c-api/c-api.h"
cat > include/module.modulemap <<'MAP'
module CSherpaOnnx {
  header "c-api.h"
  export *
}
MAP

# 合并所有静态库（不含 portaudio，录音由 app 自己负责）
libtool -static -o libsherpa-onnx-all.a $(ls "$NAME"/lib/*.a | grep -v portaudio)

mkdir -p "$ROOT/Vendor"
xcodebuild -create-xcframework -library libsherpa-onnx-all.a -headers include -output "$OUT" >/dev/null
echo "已生成：$OUT"
