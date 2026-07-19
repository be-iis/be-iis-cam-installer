#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

die() {
    echo "Error: $1" >&2
    exit 1
}

say() {
    step="$1"
    msg="$2"
    printf "%s: %s\n" "$step" "$msg"
}

require_command() {
    cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

kernel_config_enabled() {
    option="$1"
    grep -Eq "^${option}=(y|m)$" "$KDIR/.config"
}

STEP="STEP0"
say "$STEP" "Checking required tools"

require_command uname
require_command wget
require_command make
require_command gcc
require_command patch
require_command sudo

KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"

say "$STEP" "Running kernel: $KVER"
say "$STEP" "Kernel build directory: $KDIR"

STEP="STEP1"
say "$STEP" "Checking kernel compatibility and media dependencies"

KMAJOR="$(printf '%s' "$KVER" | cut -d. -f1)"
KMINOR="$(printf '%s' "$KVER" | cut -d. -f2)"

if [ "$KMAJOR" -lt 6 ] || { [ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -lt 12 ]; }; then
    die "Unsupported kernel version: $KVER (requires >= 6.12)"
fi

[ -d "$KDIR" ] || die "Kernel build directory not found: $KDIR"
[ -f "$KDIR/include/generated/autoconf.h" ] || die "Missing autoconf.h in $KDIR"
[ -f "$KDIR/Makefile" ] || die "Missing kernel Makefile in $KDIR"
[ -f "$KDIR/.config" ] || die "Missing kernel configuration: $KDIR/.config"

MISSING_CONFIG=""
for option in \
    CONFIG_OF \
    CONFIG_I2C \
    CONFIG_VIDEO_DEV \
    CONFIG_COMMON_CLK \
    CONFIG_I2C_MUX \
    CONFIG_MEDIA_CONTROLLER \
    CONFIG_GPIOLIB \
    CONFIG_V4L2_CCI_I2C \
    CONFIG_V4L2_FWNODE \
    CONFIG_VIDEO_V4L2_SUBDEV_API
do
    if ! kernel_config_enabled "$option"; then
        MISSING_CONFIG="$MISSING_CONFIG $option"
    fi
done

if [ -n "$MISSING_CONFIG" ]; then
    die "Running kernel lacks required options:$MISSING_CONFIG"
fi

STEP="STEP2"
say "$STEP" "Preparing build directory"

BUILD_DIR="${REPO_ROOT}/build/max96717"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

STEP="STEP3"
say "$STEP" "Downloading source"

KBRANCH="rpi-${KMAJOR}.${KMINOR}.y"
SOURCE_URL="https://raw.githubusercontent.com/raspberrypi/linux/${KBRANCH}/drivers/media/i2c/max96717.c"

say "$STEP" "Using Raspberry Pi kernel branch: $KBRANCH"

if ! wget -nv -O "$BUILD_DIR/max96717.c" "$SOURCE_URL"; then
    die "MAX96717 source is unavailable on Raspberry Pi kernel branch $KBRANCH"
fi

STEP="STEP3b"
say "$STEP" "Applying MAX96717 GPIO output-value fix"

PATCH_FILE="$SCRIPT_DIR/patches/max96717-gpio-set-value.patch"

if [ ! -f "$PATCH_FILE" ]; then
    PATCH_FILE="$BUILD_DIR/max96717-gpio-set-value.patch"
    PATCH_URL="https://raw.githubusercontent.com/be-iis/be-iis-cam-installer/main/tools/kernel/patches/max96717-gpio-set-value.patch"
    say "$STEP" "Local patch not found; downloading: $PATCH_URL"
    wget -nv -O "$PATCH_FILE" "$PATCH_URL" || die "Could not download GPIO fix patch"
fi

patch -d "$BUILD_DIR" -p0 --forward < "$PATCH_FILE"

STEP="STEP4"
say "$STEP" "Creating Makefile"

cat > "$BUILD_DIR/Makefile" <<'EOF'
obj-m := max96717.o

all:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

STEP="STEP5"
say "$STEP" "Building module"

make -C "$KDIR" M="$BUILD_DIR" modules

[ -f "$BUILD_DIR/max96717.ko" ] || die "max96717.ko was not created"

STEP="STEP6"
say "$STEP" "Installing module"

sudo install -D -m 644 "$BUILD_DIR/max96717.ko" "/lib/modules/$KVER/updates/max96717.ko"
sudo depmod "$KVER"

STEP="STEP7"
say "$STEP" "Done"
say "$STEP" "Try loading with:"
say "$STEP" "sudo modprobe max96717"
say "$STEP" "A matching Device Tree node/overlay is required for device probing"
