#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/clang-cache"
mkdir -p build
swiftc -parse-as-library macos/Sources/BaresipMac/Models.swift macos/Sources/BaresipMac/Diagnostics.swift macos/Sources/BaresipMac/AudioDiagnostics.swift macos/Tests/BaresipMacTests/ProtocolTests.swift -o build/protocol-tests
build/protocol-tests
codesign --verify --deep --strict 'macos/dist/Baresip Mac.app'
TEST_APP="$ROOT/build/EngineTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
# Use a fresh copy of the same resources shipped in the client.
python3 - "$ROOT" "$TEST_APP" <<'PY'
import pathlib, plistlib, shutil, sys
root, dest = map(pathlib.Path, sys.argv[1:])
source = root / 'macos/dist/Baresip Mac.app/Contents'
shutil.copytree(source / 'Resources', dest / 'Contents/Resources', dirs_exist_ok=True)
info = plistlib.loads((source / 'Info.plist').read_bytes())
info['CFBundleIdentifier'] = 'com.viegasjm.baresip-mac.tests'
info['CFBundleName'] = 'Baresip Engine Tests'
(dest / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
swiftc -parse-as-library macos/Sources/BaresipMac/Models.swift macos/Sources/BaresipMac/Diagnostics.swift macos/Sources/BaresipMac/AudioDiagnostics.swift macos/Sources/BaresipMac/Engine.swift macos/Sources/BaresipMac/Store.swift macos/Tests/EngineIntegration.swift -o "$TEST_APP/Contents/MacOS/BaresipMac"
"$TEST_APP/Contents/MacOS/BaresipMac"
python3 macos/Tests/sip_integration.py
codesign --verify --deep --strict 'macos/dist/Baresip Mac.app'
