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
    CONFIG_MEDIA_CONTROLLER \
    CONFIG_VIDEO_V4L2_SUBDEV_API \
    CONFIG_V4L2_FWNODE \
    CONFIG_COMMON_CLK \
    CONFIG_GPIOLIB \
    CONFIG_REGULATOR
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

BUILD_DIR="${REPO_ROOT}/build/imx708"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

STEP="STEP3"
say "$STEP" "Downloading source"

KBRANCH="rpi-${KMAJOR}.${KMINOR}.y"
SOURCE_URL="https://raw.githubusercontent.com/raspberrypi/linux/${KBRANCH}/drivers/media/i2c/imx708.c"

say "$STEP" "Using Raspberry Pi kernel branch: $KBRANCH"

if ! wget -nv -O "$BUILD_DIR/imx708.c" "$SOURCE_URL"; then
    die "IMX708 source is unavailable on Raspberry Pi kernel branch $KBRANCH"
fi

STEP="STEP4"
say "$STEP" "Creating Makefile"

cat > "$BUILD_DIR/Makefile" <<'EOF'
obj-m := imx708.o

all:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

STEP="STEP5"
say "$STEP" "Building module"

make -C "$KDIR" M="$BUILD_DIR" modules

[ -f "$BUILD_DIR/imx708.ko" ] || die "imx708.ko was not created"

STEP="STEP6"
say "$STEP" "Installing module"

sudo install -D -m 644 "$BUILD_DIR/imx708.ko" "/lib/modules/$KVER/updates/imx708.ko"
sudo depmod "$KVER"

STEP="STEP7"
say "$STEP" "Done"
say "$STEP" "Try loading with:"
say "$STEP" "sudo modprobe imx708"
say "$STEP" "The complete GMSL2 Device Tree overlay is required for device probing"
