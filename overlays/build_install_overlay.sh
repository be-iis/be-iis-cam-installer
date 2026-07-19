#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/max96714-max96717-imx708-overlay.dts"
OUTPUT="$SCRIPT_DIR/max96714-max96717-imx708.dtbo"
OVERLAY_DIR="/boot/firmware/overlays"

die() {
    echo "Error: $1" >&2
    exit 1
}

command -v dtc >/dev/null 2>&1 || \
    die "dtc not found; install it with: sudo apt install device-tree-compiler"

[ -f "$SOURCE" ] || die "Overlay source not found: $SOURCE"

echo "Building $OUTPUT"
dtc -@ -H epapr -I dts -O dtb -o "$OUTPUT" "$SOURCE"

echo "Installing into $OVERLAY_DIR"
sudo install -D -m 644 "$OUTPUT" "$OVERLAY_DIR/max96714-max96717-imx708.dtbo"

echo "Done. Add this to /boot/firmware/config.txt:"
echo "dtoverlay=max96714-max96717-imx708"
echo "For CAM/DISP0 instead:"
echo "dtoverlay=max96714-max96717-imx708,cam0"
