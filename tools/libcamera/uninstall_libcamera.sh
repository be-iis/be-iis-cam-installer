#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="$REPO_ROOT/build/libcamera-rpi"
BUILD_DIR="${SOURCE_DIR}-build"

die() {
    echo "Error: $1" >&2
    exit 1
}

if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = "--build-dir" ]; then
        BUILD_DIR="$2"
    else
        die "Usage: uninstall_libcamera.sh [--build-dir PATH]"
    fi
fi

command -v ninja >/dev/null 2>&1 || die "Required command not found: ninja"
command -v sudo >/dev/null 2>&1 || die "Required command not found: sudo"
[ -f "$BUILD_DIR/build.ninja" ] || die "Meson build directory not found: $BUILD_DIR"

echo "Removing files installed by the local libcamera build"
sudo ninja -C "$BUILD_DIR" uninstall
sudo ldconfig

echo "Local libcamera installation removed"
