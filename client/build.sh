#!/bin/bash
# Сборка MacScreen.app под armv7 / iOS 9 и (опционально) установка на джейлбрейкнутый iPad по USB.
#   ./build.sh            только собрать в build/MacScreen.app
#   ./build.sh install    собрать и поставить на планшет (нужен iproxy 2222 22 и ключ root в authorized_keys)
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
SDK="${SDK:-$ROOT/sdk/iPhoneOS9.3.sdk}"
[ -d "$SDK" ] || { echo "нет SDK: $SDK  (запустите scripts/get-sdk.sh)"; exit 1; }
rm -rf build && mkdir -p build/MacScreen.app
xcrun clang -arch armv7 -isysroot "$SDK" -miphoneos-version-min=9.0 -fobjc-arc -O2 -Wall -Wno-unused \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -lz \
  -Wl,-undefined,dynamic_lookup \
  main.m -o build/MacScreen.app/MacScreen 2>&1 | grep -v 'ld: warning' || true
[ -f build/MacScreen.app/MacScreen ] || { echo "сборка не удалась"; exit 1; }
cp Info.plist Icon-*.png build/MacScreen.app/
ldid -S build/MacScreen.app/MacScreen
echo "собрано: $(file build/MacScreen.app/MacScreen | cut -d: -f2)"
if [ "$1" = "install" ]; then
  S="$ROOT/scripts"
  "$S/ipad-ssh" 'rm -rf /Applications/MacScreen.app; mkdir -p /Applications/MacScreen.app'
  "$S/ipad-scp" build/MacScreen.app/MacScreen build/MacScreen.app/Info.plist build/MacScreen.app/Icon-*.png root@localhost:/Applications/MacScreen.app/
  "$S/ipad-ssh" 'chown -R root:wheel /Applications/MacScreen.app; chmod 755 /Applications/MacScreen.app/MacScreen; chmod 644 /Applications/MacScreen.app/Icon-*.png; uicache; killall -9 SpringBoard 2>/dev/null; echo установлено'
fi
