#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ADI_LINUX_DIR="${ADI_LINUX_DIR:-}"
OVERLAY_DTS=""
OVERLAY_DIR="/boot/firmware/overlays"

die() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  prepare_adi_upstream_cfe.sh --adi-linux-dir PATH [options]

Options:
  --adi-linux-dir PATH  ADI Linux source tree
  --overlay-dts PATH    generated BE-IIS overlay source
  --overlay-dir PATH    boot overlay directory
  --help                show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --adi-linux-dir)
            [ "$#" -ge 2 ] || die "Missing value for --adi-linux-dir"
            ADI_LINUX_DIR="$2"
            shift 2
            ;;
        --overlay-dts)
            [ "$#" -ge 2 ] || die "Missing value for --overlay-dts"
            OVERLAY_DTS="$2"
            shift 2
            ;;
        --overlay-dir)
            [ "$#" -ge 2 ] || die "Missing value for --overlay-dir"
            OVERLAY_DIR="$2"
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

[ -n "$ADI_LINUX_DIR" ] ||
    die "Missing --adi-linux-dir (or set ADI_LINUX_DIR)"
[ -f "$ADI_LINUX_DIR/Makefile" ] ||
    die "ADI Linux Makefile not found: $ADI_LINUX_DIR/Makefile"

for command_name in make dtc python3 sudo uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command not found: $command_name"
done

if [ -z "$OVERLAY_DTS" ]; then
    mapfile -t overlay_candidates < <(
        find "$REPO_ROOT/overlays/build" -maxdepth 1 -type f \
            -name '*-be-iis.dts' -print 2>/dev/null | sort
    )

    [ "${#overlay_candidates[@]}" -gt 0 ] ||
        die "No generated BE-IIS overlay found in $REPO_ROOT/overlays/build"
    [ "${#overlay_candidates[@]}" -eq 1 ] ||
        die "Multiple generated overlays found; select one with --overlay-dts"

    OVERLAY_DTS="${overlay_candidates[0]}"
fi

[ -f "$OVERLAY_DTS" ] || die "Overlay source not found: $OVERLAY_DTS"

KERNEL_RELEASE="$(uname -r)"
ADI_KERNEL_RELEASE="$(make -s -C "$ADI_LINUX_DIR" ARCH=arm64 kernelrelease)"
[ "$KERNEL_RELEASE" = "$ADI_KERNEL_RELEASE" ] ||
    die "Running kernel '$KERNEL_RELEASE' does not match ADI tree '$ADI_KERNEL_RELEASE'"

MODULE_RELATIVE_PATH="drivers/media/platform/raspberrypi/rp1-cfe/rp1-cfe.ko"
MODULE_SOURCE="$ADI_LINUX_DIR/$MODULE_RELATIVE_PATH"

echo "Building the upstream RP1-CFE module"
make -C "$ADI_LINUX_DIR" ARCH=arm64 \
    M=drivers/media/platform/raspberrypi/rp1-cfe modules

[ -f "$MODULE_SOURCE" ] || die "Module was not created: $MODULE_SOURCE"

echo "Installing the upstream RP1-CFE module"
sudo install -D -m 644 "$MODULE_SOURCE" \
    "/lib/modules/$KERNEL_RELEASE/updates/rp1-cfe.ko"
sudo depmod "$KERNEL_RELEASE"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OVERLAY_BACKUP="${OVERLAY_DTS}.before-upstream-cfe-${TIMESTAMP}"
sudo install -m 644 "$OVERLAY_DTS" "$OVERLAY_BACKUP"

echo "Removing the downstream CFE compatible override"
sudo python3 - "$OVERLAY_DTS" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(
    r'\n&csi([01])\s*\{\s*'
    r'compatible\s*=\s*"raspberrypi,rp1-cfe";\s*'
    r'\};\s*',
    re.MULTILINE,
)
updated, count = pattern.subn('\n', text)

if count == 0:
    if 'compatible = "raspberrypi,rp1-cfe";' in text:
        raise SystemExit("CFE override found, but its structure is unsupported")
    print("The downstream CFE override is already absent")
else:
    if count != 1:
        raise SystemExit(f"Expected one CFE override, found {count}")
    path.write_text(updated)
    print("Removed one downstream CFE override")
PY

OVERLAY_DTBO="${OVERLAY_DTS%.dts}.dtbo"
OVERLAY_NAME="$(basename "$OVERLAY_DTBO")"
INSTALLED_DTBO="$OVERLAY_DIR/$OVERLAY_NAME"
TEMP_DTBO="$(mktemp --suffix=.dtbo)"
trap 'rm -f "$TEMP_DTBO"' EXIT

echo "Compiling $OVERLAY_DTBO"
dtc -@ -H epapr -I dts -O dtb -o "$TEMP_DTBO" "$OVERLAY_DTS"
sudo install -m 644 "$TEMP_DTBO" "$OVERLAY_DTBO"

if [ -f "$INSTALLED_DTBO" ]; then
    sudo install -m 644 "$INSTALLED_DTBO" \
        "${INSTALLED_DTBO}.before-upstream-cfe-${TIMESTAMP}"
fi

echo "Installing $INSTALLED_DTBO"
sudo install -D -m 644 "$TEMP_DTBO" "$INSTALLED_DTBO"

echo "Preparation completed"
echo "Reboot after installing the patched libcamera build"
