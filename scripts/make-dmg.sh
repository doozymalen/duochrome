#!/bin/bash
# 릴리스용 DMG: 열면 Duochrome.app과 응용 프로그램 폴더 바로가기가 나란히 있어 끌어 놓으면 설치된다.
# 보정표는 빼고(DUOCHROME_PUBLIC=1) 새로 빌드한다. 결과: build/Duochrome.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"; APP="$BUILD/Duochrome.app"
STAGE="$BUILD/dmg"; RW="$BUILD/Duochrome-rw.dmg"; DMG="$BUILD/Duochrome.dmg"
VOL="Duochrome"

DUOCHROME_PUBLIC=1 DUOCHROME_NO_INSTALL=1 bash "$ROOT/scripts/build-app.sh"

echo "==> dmg"
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Duochrome.app"
ln -s /Applications "$STAGE/Applications"

# 같은 이름의 볼륨이 붙어 있으면 창 배치가 엉뚱한 곳에 걸린다
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -quiet || true

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$RW" -quiet
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS|Apple_APFS/ {print $1; exit}')"

# 창 모양: 아이콘 보기, 앱은 왼쪽·응용 프로그램은 오른쪽. Finder 권한이 없으면 건너뛴다 (끌어 놓기는 그대로 된다)
osascript <<EOF || echo "창 배치를 건너뜀 (시스템 설정 → 개인정보 보호 → 자동화에서 터미널의 Finder 제어를 허용하면 적용)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 460}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "Duochrome.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$STAGE" "$RW"
echo
echo "DMG 완료: $DMG"
