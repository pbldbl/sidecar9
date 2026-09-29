#!/usr/bin/env python3
"""В SDK от theos libSystem.tbd реэкспортирует библиотеки, для части которых нет .tbd (liblaunch).
Новый ld из Xcode 15+ на этом падает: "file not found: /usr/lib/system/liblaunch.dylib".
Скрипт создаёт пустые заглушки для всех отсутствующих."""
import os, re, sys
sdk = sys.argv[1]
txt = open(f"{sdk}/usr/lib/libSystem.tbd").read()
m = re.search(r"re-exports:\s*\[(.*?)\]", txt, re.S)
libs = [x.strip() for x in m.group(1).replace("\n", " ").split(",") if x.strip()]
made = 0
for l in libs:
    path = f"{sdk}{l}".replace(".dylib", ".tbd")
    if os.path.exists(path):
        continue
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(f"---\narchs:           [ armv7, armv7s, arm64 ]\nplatform:        ios\ninstall-name:    {l}\nexports:\n  - archs:           [ armv7, armv7s, arm64 ]\n    symbols:         [ ]\n...\n")
    made += 1
print(f"заглушек создано: {made}")
