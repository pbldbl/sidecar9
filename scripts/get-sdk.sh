#!/bin/bash
# Скачивает iOS 9.3 SDK из theos/sdks и дописывает заглушку liblaunch.tbd, без которой современный ld не линкует armv7.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/sdk" && cd "$ROOT/sdk"
if [ ! -d iPhoneOS9.3.sdk ]; then
  rm -rf sdks-git
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks sdks-git
  (cd sdks-git && git sparse-checkout set iPhoneOS9.3.sdk)
  mv sdks-git/iPhoneOS9.3.sdk . && rm -rf sdks-git
fi
python3 "$ROOT/scripts/patch-sdk.py" "$ROOT/sdk/iPhoneOS9.3.sdk"
echo "SDK готов: $ROOT/sdk/iPhoneOS9.3.sdk"
