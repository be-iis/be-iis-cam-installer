#!/usr/bin/env bash
#
# Remove only dynamically loaded BE-IIS GMSL IMX708 overlays.
#
# This does not touch config.txt and does not remove Raspberry Pi standard
# camera overlays. Stop all rpicam/libcamera programs before running it.
#
set -Eeuo pipefail

(( EUID == 0 )) || { echo 'Run with sudo.' >&2; exit 1; }
command -v dtoverlay >/dev/null || { echo 'dtoverlay not found.' >&2; exit 1; }

# The kernel cannot safely remove an overlay while its I2C client is bound.
for device in 11-0053 11-0052; do
	driver="/sys/bus/i2c/devices/${device}/driver"
	if [[ -L "$driver" ]]; then
		echo "$device" > "$driver/unbind"
		echo "Unbound ${device}"
	fi
done

mapfile -t overlays < <(
	dtoverlay -l |
		awk '/imx708-gmsl-link-(a|b)/ { id=$1; sub(/:/, "", id); print id }'
)

# Overlays have to be removed in reverse load order.
for ((index=${#overlays[@]} - 1; index >= 0; index--)); do
	id="${overlays[index]}"
	dtoverlay -r "$id"
	echo "Removed overlay ${id}"
done

if (( ${#overlays[@]} == 0 )); then
	echo 'No BE-IIS GMSL camera overlay is loaded.'
fi
