#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Compile and load the two manual IMX708 overlays.
# Run "make init-a-b" first so all four I2C aliases exist.
# Link A is wired to RP1 CSI1; Link B is wired to RP1 CSI0.
set -Eeuo pipefail

(( EUID == 0 )) || { echo "Run with sudo." >&2; exit 1; }
command -v dtc >/dev/null || { echo "ERROR: dtc is not installed." >&2; exit 1; }
command -v dtoverlay >/dev/null || { echo "ERROR: dtoverlay is not installed." >&2; exit 1; }

if dtoverlay -l | grep -qE 'imx708-gmsl-link-(a|b)'; then
  echo "ERROR: A BE-IIS camera overlay is already loaded. Run 'make unoverlay' first." >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay_dir="/boot/firmware/overlays"

dtc -@ -H epapr -I dts -O dtb \
  -o "$overlay_dir/imx708-gmsl-link-a.dtbo" \
  "$root/overlays/imx708-gmsl-link-a.dts"
dtc -@ -H epapr -I dts -O dtb \
  -o "$overlay_dir/imx708-gmsl-link-b.dtbo" \
  "$root/overlays/imx708-gmsl-link-b.dts"

dtoverlay imx708-gmsl-link-a
dtoverlay imx708-gmsl-link-b
sleep 2
dtoverlay -l
