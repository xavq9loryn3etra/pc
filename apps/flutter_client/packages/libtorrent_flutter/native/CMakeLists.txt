# native/CMakeLists.txt — builds libtorrent from source together with the
# torrent bridge, producing the binaries we publish ourselves (see
# .github/workflows/build-libtorrent-native.yml) instead of relying on the
# upstream plugin's GitHub releases, which no longer exist.
#
#   Android: liblibtorrent_flutter.so (libtorrent linked in statically)
#   iOS:     liblibtorrent_flutter.a  (bridge only; build_ios.sh merges it
#            with libtorrent-rasterbar.a into one archive)
#
# Required: -DLIBTORRENT_SOURCE_DIR=<libtorrent checkout, with submodules>
#           -DBoost_INCLUDE_DIR=<boost headers>

cmake_minimum_required(VERSION 3.16)
project(libtorrent_flutter_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT LIBTORRENT_SOURCE_DIR)
    message(FATAL_ERROR "Set LIBTORRENT_SOURCE_DIR to a libtorrent checkout")
endif()

# Builds only what the bridge links against (no tools/examples/tests).
add_subdirectory("${LIBTORRENT_SOURCE_DIR}" libtorrent EXCLUDE_FROM_ALL)

if(ANDROID)
    add_library(libtorrent_flutter SHARED ../src/torrent_bridge.cpp)
    target_link_options(libtorrent_flutter PRIVATE
        # Keep libtorrent's own symbols out of the export table; only the
        # bridge's lt_* entry points (marked visibility("default")) remain.
        "-Wl,--exclude-libs,ALL"
        # Required by Google Play for Android 15+ devices with 16 KB pages.
        "-Wl,-z,max-page-size=16384"
    )
else()
    add_library(libtorrent_flutter STATIC ../src/torrent_bridge.cpp)
endif()

target_compile_definitions(libtorrent_flutter PRIVATE TORRENT_BRIDGE_EXPORTS)
# Linking the target (not a prebuilt .a) also carries libtorrent's public
# compile definitions, so the bridge is compiled against the same ABI.
target_link_libraries(libtorrent_flutter PRIVATE torrent-rasterbar)

set_target_properties(libtorrent_flutter PROPERTIES
    C_VISIBILITY_PRESET   hidden
    CXX_VISIBILITY_PRESET hidden
    PREFIX ""
    OUTPUT_NAME "liblibtorrent_flutter"
)
