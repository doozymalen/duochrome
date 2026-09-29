#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"; APP="$BUILD/Duochrome.app"

echo "==> swift build"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/Duochrome"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Duochrome"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Default look tables (camera-fitted)
[ -d "$ROOT/Resources/Looks" ] && [ "${DUOCHROME_PUBLIC:-}" = "" ] && cp -R "$ROOT/Resources/Looks" "$APP/Contents/Resources/Looks"
# AppleScript dictionary
cp "$ROOT/Resources/Duochrome.sdef" "$APP/Contents/Resources/Duochrome.sdef"
cp "$ROOT/Resources/ai-setup.sh" "$APP/Contents/Resources/ai-setup.sh"
cp "$ROOT/Resources/colab-remote.py" "$APP/Contents/Resources/colab-remote.py"
cp "$ROOT/Resources/tether-helper.py" "$APP/Contents/Resources/tether-helper.py"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc sign"
codesign --force --sign - "$APP"
codesign --verify "$APP" && echo "서명 확인"
echo
echo "빌드 완료: $APP"

# Install into /Applications. Quit the running app first
if [ "${DUOCHROME_NO_INSTALL:-}" = "" ]; then
  pkill -x Duochrome 2>/dev/null && sleep 1
  rm -rf /Applications/Duochrome.app
  cp -R "$APP" /Applications/Duochrome.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Duochrome.app
  touch /Applications/Duochrome.app
  echo "설치: /Applications/Duochrome.app"
fi
