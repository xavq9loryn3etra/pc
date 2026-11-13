#!/usr/bin/env bash
# Builds liblibtorrent_flutter.so for one Android ABI and zips it the way
# android/build.gradle expects: the .so at the zip root.
#
#   build_android.sh <abi> <out_dir>
#
# Needs ANDROID_NDK_HOME, plus WORK_DIR populated by fetch_sources.sh.
set -euo pipefail

abi="$1"
out_dir="$2"
: "${ANDROID_NDK_HOME:?}" "${WORK_DIR:?}"

here="$(cd "$(dirname "$0")" && pwd)"
build="$WORK_DIR/build-android-$abi"
llvm_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

cmake -S "$here" -B "$build" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$abi" \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DLIBTORRENT_SOURCE_DIR="$WORK_DIR/libtorrent" \
  -DBoost_INCLUDE_DIR="$WORK_DIR/boost" \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON
cmake --build "$build" --target libtorrent_flutter --parallel "$(nproc)"

so="$build/liblibtorrent_flutter.so"
"$llvm_bin/llvm-strip" --strip-unneeded "$so"

# The Dart side looks every entry point up by name, so an .so without them
# would load fine and then fail at runtime.
exported=$("$llvm_bin/llvm-nm" -D --defined-only "$so" | grep -c ' T lt_' || true)
echo "$abi: $exported lt_* symbols exported, $(du -h "$so" | cut -f1)"
[ "$exported" -gt 0 ] || { echo "no lt_* symbols exported" >&2; exit 1; }

mkdir -p "$out_dir"
zip -j "$out_dir/android-native-lib-$abi.zip" "$so"
