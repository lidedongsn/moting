#!/usr/bin/env bash
# 构建 Apple Silicon Release 包；使用临时签名，不包含开发者证书或公证票据。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/releases"
DERIVED="$ROOT/.build/xcode"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$ROOT/.build/package-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [ "$(uname -m)" != arm64 ]; then
  echo "当前发布包仅支持在 Apple Silicon Mac 上构建。" >&2
  exit 1
fi
if [ ! -d "$ROOT/Vendor/CSherpaOnnx.xcframework" ]; then
  echo "请先运行 Scripts/fetch-sherpa-onnx.sh。" >&2
  exit 1
fi
if [ ! -f "$ROOT/App/Local.xcconfig" ]; then
  cp "$ROOT/App/Local.xcconfig.example" "$ROOT/App/Local.xcconfig"
fi

(cd "$ROOT/App" && xcodegen generate)
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
xcodebuild -project "$ROOT/App/Moting.xcodeproj" -scheme Moting \
  -configuration Release -derivedDataPath "$DERIVED" -jobs 2 \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO build > "$OUT/build.log" 2>&1 || {
    echo "构建失败，完整日志：$OUT/build.log" >&2
    exit 1
  }

PACKAGE="$STAGE/Moting"
APP="$PACKAGE/Moting.app"
mkdir -p "$PACKAGE"
ditto --norsrc --noextattr --noqtn "$DERIVED/Build/Products/Release/Moting.app" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
test "$(lipo -archs "$APP/Contents/MacOS/Moting")" = arm64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.lidedongsn.moting

# 将第三方许可放在包内及应用资源中，使单独移动 .app 后仍能保留声明。
for destination in "$PACKAGE" "$APP/Contents/Resources/Licenses"; do
  mkdir -p "$destination/docs"
  cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$destination/"
  ditto --norsrc --noextattr --noqtn "$ROOT/docs/licenses" "$destination/docs/licenses"
done
cp "$ROOT/docs/releases/INSTALL.zh-CN.txt" "$PACKAGE/README.txt"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# 检查打包内容；不输出敏感值。
python3 - "$PACKAGE" "$ROOT" <<'PY'
import pathlib, re, subprocess, sys
package, root = map(pathlib.Path, sys.argv[1:])
private_values = [str(pathlib.Path.home()).encode() + b"/"]
email = subprocess.check_output(["git", "-C", str(root), "config", "user.email"]).strip()
if email:
    private_values.append(email)
config = (root / "App/Local.xcconfig").read_text()
team = re.search(r"^DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+)", config, re.M)
if team:
    private_values.append(team[1].encode())
for path in package.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix in {".pcm", ".wav", ".sqlite", ".db", ".f32", ".onnx", ".p12", ".mobileprovision"}:
        raise SystemExit("发布包中发现不应分发的文件：" + str(path.relative_to(package)))
    data = path.read_bytes()
    if any(value in data for value in private_values):
        raise SystemExit("发布包中发现本机身份信息：" + str(path.relative_to(package)))
print("发布包隐私检查通过")
PY

NAME="Moting-${VERSION}-macOS-arm64.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$PACKAGE" "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "发布包：$OUT/$NAME"
echo "校验文件：$OUT/$NAME.sha256"
