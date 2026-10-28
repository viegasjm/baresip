#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
CMAKE="${CMAKE:-cmake}"
BREW_PREFIX="$(brew --prefix)"
if [[ ! -d vendor/re/.git ]]; then
  git clone --depth 1 --branch v4.12.0 https://github.com/baresip/re.git vendor/re
fi
[[ "$(git -C vendor/re rev-parse HEAD)" == "65555dad439de9d6a81b3ee6092b9c096585249b" ]] || { echo 'Unexpected libre revision'; exit 1; }
"$CMAKE" -S vendor/re -B build/re -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$ROOT/build/deps" -DOPENSSL_ROOT_DIR="$BREW_PREFIX/opt/openssl@3"
"$CMAKE" --build build/re -j 8
"$CMAKE" --install build/re
"$CMAKE" -S . -B build/engine -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$ROOT/build/deps;$BREW_PREFIX" -DRE_INCLUDE_DIR="$ROOT/build/deps/include/re" -DRE_LIBRARY="$ROOT/build/deps/lib/libre.dylib" -DSTATIC=ON '-DMODULES=account;menu;ctrl_tcp;g711;g722;opus;coreaudio;aufile;auconv;auresamp;stun;turn;ice;srtp;uuid' -DOPUS_INCLUDE_DIR="$BREW_PREFIX/opt/opus/include" -DOPUS_LIBRARY="$BREW_PREFIX/opt/opus/lib/libopus.dylib" -DSPANDSP_INCLUDE_DIR="$BREW_PREFIX/include" -DSPANDSP_LIBRARY="$BREW_PREFIX/lib/libspandsp.dylib"
"$CMAKE" --build build/engine --target g722 opus -j 8
"$CMAKE" --build build/engine -j 8
export CLANG_MODULE_CACHE_PATH="$ROOT/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/build/clang-cache"
swift build --package-path macos --scratch-path build/swift --cache-path "$ROOT/build/swift-cache" --disable-sandbox -c release
python3 macos/scripts/bundle.py
