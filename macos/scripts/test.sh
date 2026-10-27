#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/clang-cache"
mkdir -p build
swiftc -parse-as-library macos/Sources/BaresipMac/Models.swift macos/Sources/BaresipMac/Diagnostics.swift macos/Tests/BaresipMacTests/ProtocolTests.swift -o build/protocol-tests
build/protocol-tests
TEST_APP="$ROOT/build/EngineTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
# Use a fresh copy of the same resources shipped in the client.
python3 - "$ROOT" "$TEST_APP" <<'PY'
import pathlib, shutil, sys
root, dest = map(pathlib.Path, sys.argv[1:])
source = root / 'macos/dist/Baresip Mac.app/Contents'
shutil.copytree(source / 'Resources', dest / 'Contents/Resources', dirs_exist_ok=True)
shutil.copy2(source / 'Info.plist', dest / 'Contents/Info.plist')
PY
swiftc -parse-as-library macos/Sources/BaresipMac/Models.swift macos/Sources/BaresipMac/Diagnostics.swift macos/Sources/BaresipMac/AudioDiagnostics.swift macos/Sources/BaresipMac/Engine.swift macos/Tests/EngineIntegration.swift -o "$TEST_APP/Contents/MacOS/BaresipMac"
"$TEST_APP/Contents/MacOS/BaresipMac"
python3 macos/Tests/sip_integration.py
codesign --verify --deep --strict 'macos/dist/Baresip Mac.app'
