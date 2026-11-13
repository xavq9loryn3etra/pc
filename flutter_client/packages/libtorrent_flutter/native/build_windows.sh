#!/usr/bin/env bash
# Builds libtorrent_flutter.dll for Windows (x64): libtorrent linked in
# statically, as for Android. Runs in Git Bash with Visual Studio's C++
# tools installed; the sources come from fetch_sources.sh.
#
#   build_windows.sh <out_dir>
#
# Leaves windows-native-lib-x64.zip in <out_dir>, the file the plugin's
# windows/CMakeLists.txt downloads and unpacks into prebuilt/windows/.
set -euo pipefail

out_dir="$1"
: "${WORK_DIR:?}"
here="$(cd "$(dirname "$0")" && pwd)"
build="$WORK_DIR/build-windows-x64"

cmake -S "$here" -B "$build" -A x64 \
  -DLIBTORRENT_SOURCE_DIR="$WORK_DIR/libtorrent" \
  -DBoost_INCLUDE_DIR="$WORK_DIR/boost" \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON
cmake --build "$build" --target libtorrent_flutter --config Release --parallel

dll="$build/Release/libtorrent_flutter.dll"
[ -f "$dll" ] || { echo "no $dll" >&2; exit 1; }
echo "x64: $(du -h "$dll" | cut -f1)"

# Zipped as x64/libtorrent_flutter.dll, the layout prebuilt/windows/ wants.
stage="$WORK_DIR/stage-windows"
rm -rf "$stage" && mkdir -p "$stage/x64"
cp "$dll" "$stage/x64/"
mkdir -p "$out_dir"
out_abs="$(cd "$out_dir" && pwd)"
(cd "$stage" && cmake -E tar cf "$out_abs/windows-native-lib-x64.zip" --format=zip x64)
