#!/usr/bin/env bash
# Builds libtorrent_flutter.xcframework (static, device + simulator) and
# zips it the way ios/libtorrent_flutter.podspec expects: the xcframework's
# contents (Info.plist, ios-arm64/, ios-arm64_x86_64-simulator/) at the zip
# root.
#
#   build_ios.sh <out_dir>
#
# Needs Xcode, plus WORK_DIR populated by fetch_sources.sh.
set -euo pipefail

out_dir="$(mkdir -p "$1" && cd "$1" && pwd)"
: "${WORK_DIR:?}"

here="$(cd "$(dirname "$0")" && pwd)"
min_ios=13.0

# Builds one architecture and merges libtorrent + the bridge into a single
# liblibtorrent_flutter.a, which the podspec force_loads so every lt_*
# symbol is there for DynamicLibrary.process() to find.
build_slice() {
  local name="$1" sysroot="$2" arch="$3"
  local build="$WORK_DIR/build-ios-$name"

  cmake -S "$here" -B "$build" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_ios" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBTORRENT_SOURCE_DIR="$WORK_DIR/libtorrent" \
    -DBoost_INCLUDE_DIR="$WORK_DIR/boost" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON
  cmake --build "$build" --target libtorrent_flutter --parallel

  local rasterbar
  rasterbar="$(find "$build/libtorrent" -name 'libtorrent-rasterbar.a' | head -n 1)"
  mkdir -p "$build/merged"
  libtool -static -o "$build/merged/liblibtorrent_flutter.a" \
    "$build/liblibtorrent_flutter.a" "$rasterbar"

  local exported
  exported=$(nm -gU "$build/merged/liblibtorrent_flutter.a" 2>/dev/null | grep -c ' T _lt_' || true)
  echo "$name: $exported lt_* symbols"
  [ "$exported" -gt 0 ] || { echo "no lt_* symbols in $name" >&2; exit 1; }
}

build_slice device    iphoneos        arm64
build_slice sim-arm64 iphonesimulator arm64
build_slice sim-x64   iphonesimulator x86_64

# Simulator slices are built separately (ar can't archive fat objects) and
# joined here.
sim="$WORK_DIR/build-ios-sim"
mkdir -p "$sim"
lipo -create \
  "$WORK_DIR/build-ios-sim-arm64/merged/liblibtorrent_flutter.a" \
  "$WORK_DIR/build-ios-sim-x64/merged/liblibtorrent_flutter.a" \
  -output "$sim/liblibtorrent_flutter.a"

xcframework="$WORK_DIR/libtorrent_flutter.xcframework"
rm -rf "$xcframework"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/build-ios-device/merged/liblibtorrent_flutter.a" \
  -library "$sim/liblibtorrent_flutter.a" \
  -output "$xcframework"

# The podspec force_loads these exact paths.
test -f "$xcframework/ios-arm64/liblibtorrent_flutter.a"
test -f "$xcframework/ios-arm64_x86_64-simulator/liblibtorrent_flutter.a"

rm -f "$out_dir/ios-native-lib.zip"
(cd "$xcframework" && zip -qry "$out_dir/ios-native-lib.zip" .)
