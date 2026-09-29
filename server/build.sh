#!/bin/bash
# Сборка ScreenServe.app (macOS 13+) и, с ключом install, установка в /Applications.
# Сервер упакован как приложение с постоянным bundle id и подписью сертификатом разработчика: только так
# macOS запоминает разрешения Screen Recording / Accessibility между пересборками. После включения
# переключателя в настройках процесс нужно перезапустить, само приложение об этом позаботится.
set -e
cd "$(dirname "$0")"
APP=build/ScreenServe.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
clang -c -O2 -fobjc-arc vdisplay.m -o vdisplay.o
swiftc -O -import-objc-header vdisplay.h -o "$APP/Contents/MacOS/screenserve" screenserve.swift vdisplay.o -framework Foundation
rm -f vdisplay.o
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ID="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')}"
if [ -n "$ID" ]; then
  codesign --force --deep --options runtime --timestamp=none -s "$ID" "$APP"; echo "подписано: $ID"
else
  codesign --force --deep -s - "$APP"; echo "подписано ad-hoc (разрешения слетят при следующей сборке)"
fi
echo "собрано: $APP"
if [ "$1" = "install" ]; then
  rm -rf /Applications/ScreenServe.app && cp -R "$APP" /Applications/ScreenServe.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ScreenServe.app
  echo "установлено: /Applications/ScreenServe.app"
fi
