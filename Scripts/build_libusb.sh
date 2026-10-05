#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_source_root="$PWD"
task_build_root=$(mktemp -d "${TMPDIR:-/tmp}/microtech-libusb.XXXXXX")
tar -xjf tools/vendor/libusb-1.0.29.tar.bz2 -C "$task_build_root"
cd "$task_build_root/libusb-1.0.29"
env MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS='-O2 -mmacosx-version-min=14.0' ./configure --disable-shared --enable-static --disable-dependency-tracking
make -j4
cp libusb/.libs/libusb-1.0.a "$task_source_root/tools/vendor/libusb-1.0.a"
printf 'Built libusb for macOS 14 or later. Build folder: %s\n' "$task_build_root"
