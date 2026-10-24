#!/usr/bin/env bash
# Downloads the libtorrent and Boost sources the native build compiles
# against into $WORK_DIR. Versions come from the environment so the
# workflow pins them in one place.
#
#   LIBTORRENT_VERSION  git tag, e.g. v2.0.11
#   BOOST_VERSION       e.g. 1.86.0 (only the headers are used)
#   WORK_DIR            where to put them
set -euo pipefail

: "${LIBTORRENT_VERSION:?}" "${BOOST_VERSION:?}" "${WORK_DIR:?}"
mkdir -p "$WORK_DIR"

git clone --quiet --depth 1 --branch "$LIBTORRENT_VERSION" \
  --recurse-submodules --shallow-submodules \
  https://github.com/arvidn/libtorrent.git "$WORK_DIR/libtorrent"

boost_dir="boost_${BOOST_VERSION//./_}"
curl -fsSL "https://archives.boost.io/release/${BOOST_VERSION}/source/${boost_dir}.tar.gz" \
  | tar xz -C "$WORK_DIR" "${boost_dir}/boost"
mv "$WORK_DIR/$boost_dir" "$WORK_DIR/boost"
