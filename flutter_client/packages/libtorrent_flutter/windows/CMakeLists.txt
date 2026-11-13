# Windows CMakeLists.txt — uses prebuilt lib if available, otherwise builds from source.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "libtorrent_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

set(_LTF_TARGET_ARCH "")
if(DEFINED CMAKE_GENERATOR_PLATFORM AND CMAKE_GENERATOR_PLATFORM)
  set(_LTF_TARGET_ARCH "${CMAKE_GENERATOR_PLATFORM}")
elseif(DEFINED CMAKE_VS_PLATFORM_NAME AND CMAKE_VS_PLATFORM_NAME)
  set(_LTF_TARGET_ARCH "${CMAKE_VS_PLATFORM_NAME}")
else()
  set(_LTF_TARGET_ARCH "$ENV{PROCESSOR_ARCHITECTURE}")
endif()

string(TOLOWER "${_LTF_TARGET_ARCH}" _LTF_TARGET_ARCH_LOWER)
if(_LTF_TARGET_ARCH_LOWER MATCHES "arm64|aarch64")
  set(LTF_WINDOWS_ARCH "arm64")
else()
  set(LTF_WINDOWS_ARCH "x64")
endif()

# The package's real folder: Flutter reaches it through a symlink
# (flutter/ephemeral/.plugin_symlinks), and newer CMake refuses to extract
# the prebuilt zip "through symlink" there (it failed on GitHub's runners).
get_filename_component(_LTF_PKG_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.." REALPATH)
set(PREBUILT_DIR "${_LTF_PKG_DIR}/prebuilt/windows")
set(PREBUILT_DLL "${PREBUILT_DIR}/${LTF_WINDOWS_ARCH}/libtorrent_flutter.dll")

option(LIBTORRENT_FLUTTER_SKIP_DOWNLOAD "Skip downloading prebuilt native lib" OFF)

# The DLL comes from this repo's release (native/PREBUILT_RELEASE_URL, built
# by .github/workflows/build-libtorrent-native.yml), as Android's and iOS's
# do. A ".source" file beside it records which release, so bumping that URL
# replaces a copy downloaded before.
set(_RELEASE_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../native/PREBUILT_RELEASE_URL")
set(_RELEASE_BASE "")
if(EXISTS "${_RELEASE_FILE}")
  file(READ "${_RELEASE_FILE}" _RELEASE_BASE)
  string(STRIP "${_RELEASE_BASE}" _RELEASE_BASE)
endif()
set(_SOURCE_FILE "${PREBUILT_DIR}/${LTF_WINDOWS_ARCH}/.source")
set(_ZIP_NAME "windows-native-lib-${LTF_WINDOWS_ARCH}.zip")

# The zip's expected SHA-256, from native/PREBUILT_SHA256 (sha256sum format,
# one line per zip). The .source marker holds release + hash, so a changed
# hash forces a re-download.
set(_EXPECTED_HASH "")
set(_HASH_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../native/PREBUILT_SHA256")
if(EXISTS "${_HASH_FILE}")
  file(STRINGS "${_HASH_FILE}" _HASH_LINES)
  foreach(_LINE IN LISTS _HASH_LINES)
    if(_LINE MATCHES "^([0-9a-fA-F]+)[ \t]+\\*?(.+)$")
      set(_LINE_HASH "${CMAKE_MATCH_1}")
      string(STRIP "${CMAKE_MATCH_2}" _LINE_NAME)
      if("${_LINE_NAME}" STREQUAL "${_ZIP_NAME}")
        string(TOLOWER "${_LINE_HASH}" _EXPECTED_HASH)
      endif()
    endif()
  endforeach()
endif()
set(_MARKER "${_RELEASE_BASE} ${_EXPECTED_HASH}")

set(_HAVE_CURRENT FALSE)
if(EXISTS "${PREBUILT_DLL}" AND EXISTS "${_SOURCE_FILE}")
  file(READ "${_SOURCE_FILE}" _SOURCE)
  string(STRIP "${_SOURCE}" _SOURCE)
  if("${_SOURCE}" STREQUAL "${_MARKER}")
    set(_HAVE_CURRENT TRUE)
  endif()
endif()

if(NOT _HAVE_CURRENT AND NOT LIBTORRENT_FLUTTER_SKIP_DOWNLOAD)
  if(NOT "${_RELEASE_BASE}" STREQUAL "")
      if("${_EXPECTED_HASH}" STREQUAL "")
        message(FATAL_ERROR "libtorrent_flutter: native/PREBUILT_SHA256 has no line for ${_ZIP_NAME}. Add the hash from the release's SHA256SUMS.")
      endif()
      set(_DL_URL "${_RELEASE_BASE}/${_ZIP_NAME}")
      set(_ZIP "${CMAKE_CURRENT_BINARY_DIR}/${_ZIP_NAME}")
      message(STATUS "libtorrent_flutter: downloading prebuilt from ${_DL_URL}")
      file(DOWNLOAD "${_DL_URL}" "${_ZIP}" SHOW_PROGRESS STATUS _DL_STATUS TLS_VERIFY ON)
      list(GET _DL_STATUS 0 _DL_CODE)
      if(_DL_CODE EQUAL 0)
        file(SHA256 "${_ZIP}" _ACTUAL_HASH)
        if(NOT "${_ACTUAL_HASH}" STREQUAL "${_EXPECTED_HASH}")
          file(REMOVE "${_ZIP}")
          message(FATAL_ERROR "libtorrent_flutter: ${_ZIP_NAME} from ${_DL_URL} has SHA-256 ${_ACTUAL_HASH}, expected ${_EXPECTED_HASH} (native/PREBUILT_SHA256). Refusing to use it.")
        endif()
        file(MAKE_DIRECTORY "${PREBUILT_DIR}")
        execute_process(
          COMMAND "${CMAKE_COMMAND}" -E tar xf "${_ZIP}"
          WORKING_DIRECTORY "${PREBUILT_DIR}"
          RESULT_VARIABLE _UNZIP_RC
        )
        file(REMOVE "${_ZIP}")
        if(_UNZIP_RC EQUAL 0)
          file(WRITE "${_SOURCE_FILE}" "${_MARKER}")
        else()
          message(WARNING "libtorrent_flutter: failed to extract prebuilt zip (rc=${_UNZIP_RC}); will build from source")
        endif()
      else()
        message(WARNING "libtorrent_flutter: prebuilt download failed (${_DL_STATUS}); will build from source")
      endif()
  endif()
endif()

if(EXISTS "${PREBUILT_DLL}")
  message(STATUS "Using prebuilt Windows ${LTF_WINDOWS_ARCH} native library")
  file(GLOB PREBUILT_DEPS "${PREBUILT_DIR}/${LTF_WINDOWS_ARCH}/*.dll")
  set(libtorrent_flutter_bundled_libraries
    ${PREBUILT_DEPS}
    PARENT_SCOPE
  )
else()
  message(STATUS "Building from source (no prebuilt found at ${PREBUILT_DLL})")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
  set(libtorrent_flutter_bundled_libraries
    $<TARGET_FILE:libtorrent_flutter>
    PARENT_SCOPE
  )
endif()