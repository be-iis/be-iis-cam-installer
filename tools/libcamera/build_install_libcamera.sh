#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_FILES=(
    "$PATCH_DIR/0001-rpi-gmsl-multi-source-upstream-cfe.patch"
    "$PATCH_DIR/0002-rpi-upstream-cfe-channel-routing.patch"
)

SOURCE_DIR="$REPO_ROOT/build/libcamera-rpi"
BUILD_DIR=""
LIBCAMERA_TAG="v0.7.1+rpt20260609"
PREFIX="/usr/local"

die() {
    echo "Error: $1" >&2
    exit 1
}

say() {
    printf '%s\n' "$1"
}

usage() {
    cat <<'EOF'
Usage:
  build_install_libcamera.sh [options]

Options:
  --source-dir PATH   libcamera source directory
  --build-dir PATH    Meson build directory
  --tag TAG           Raspberry Pi libcamera tag
  --prefix PATH       installation prefix, default: /usr/local
  --help              show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-dir)
            [ "$#" -ge 2 ] || die "Missing value for --source-dir"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --build-dir)
            [ "$#" -ge 2 ] || die "Missing value for --build-dir"
            BUILD_DIR="$2"
            shift 2
            ;;
        --tag)
            [ "$#" -ge 2 ] || die "Missing value for --tag"
            LIBCAMERA_TAG="$2"
            shift 2
            ;;
        --prefix)
            [ "$#" -ge 2 ] || die "Missing value for --prefix"
            PREFIX="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[ -n "$BUILD_DIR" ] || BUILD_DIR="${SOURCE_DIR}-build"

for command_name in gcc git meson ninja pkg-config sudo; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command not found: $command_name"
done

for patch_file in "${PATCH_FILES[@]}"; do
    [ -f "$patch_file" ] || die "Patch file not found: $patch_file"
done

MULTIARCH="$(gcc -print-multiarch)"
[ -n "$MULTIARCH" ] || die "Could not determine the compiler multiarch tuple"

if ! pkg-config --exists libpisp; then
    die "libpisp development files not found; install libpisp-dev"
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
    [ ! -e "$SOURCE_DIR" ] ||
        die "Source path exists but is not a Git repository: $SOURCE_DIR"

    say "Cloning Raspberry Pi libcamera tag $LIBCAMERA_TAG"
    git clone --depth 1 --branch "$LIBCAMERA_TAG" \
        https://github.com/raspberrypi/libcamera.git \
        "$SOURCE_DIR"
else
    say "Using existing libcamera source: $SOURCE_DIR"
fi

CURRENT_TAG="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
if [ "$CURRENT_TAG" != "$LIBCAMERA_TAG" ]; then
    die "Source checkout is '$CURRENT_TAG', expected '$LIBCAMERA_TAG'"
fi

for patch_file in "${PATCH_FILES[@]}"; do
    patch_name="$(basename "$patch_file")"

    if git -C "$SOURCE_DIR" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        say "Patch is already applied: $patch_name"
    elif git -C "$SOURCE_DIR" apply --check "$patch_file"; then
        say "Applying patch: $patch_name"
        git -C "$SOURCE_DIR" apply "$patch_file"
    else
        die "Patch does not apply cleanly: $patch_name"
    fi
done

MESON_OPTIONS=(
    --buildtype=release
    --prefix="$PREFIX"
    --libdir="lib/$MULTIARCH"
    -Dpipelines=rpi/pisp,rpi/vc4
    -Dipas=rpi/pisp,rpi/vc4
    -Dcam=disabled
    -Dqcam=disabled
    -Dgstreamer=disabled
    -Dpycamera=disabled
    -Dtest=false
    -Dlc-compliance=disabled
    -Ddocumentation=disabled
)

say "Configuring libcamera"
if [ -f "$BUILD_DIR/build.ninja" ]; then
    meson setup "$BUILD_DIR" "$SOURCE_DIR" --wipe "${MESON_OPTIONS[@]}"
else
    [ ! -e "$BUILD_DIR" ] || [ -d "$BUILD_DIR" ] ||
        die "Build path exists and is not a directory: $BUILD_DIR"
    meson setup "$BUILD_DIR" "$SOURCE_DIR" "${MESON_OPTIONS[@]}"
fi

say "Building libcamera"
ninja -C "$BUILD_DIR"

say "Installing patched libcamera into $PREFIX"
sudo ninja -C "$BUILD_DIR" install
sudo ldconfig

say "Installation completed"
say "Reboot, then verify with: rpicam-hello --list-cameras"
