#!/usr/bin/env bash
# Remove the dynamically loaded BE-IIS Link A overlay.
# Stop all rpicam/libcamera programs before running this script.
set -Eeuo pipefail

(( EUID == 0 )) || { echo 'Run with sudo.' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
i2c_device="$(python3 "$script_dir/camera_profile.py" i2c-device --profile "${1:-imx708-revb}")"
loaded="$(dtoverlay -l)"
overlay_id="$(awk '$2 == "imx708-gmsl-link-a" { sub(/:$/, "", $1); print $1 }' <<<"$loaded")"

if [[ -z "$overlay_id" ]]; then
	echo 'No BE-IIS GMSL camera overlay is loaded.'
	exit 0
fi

bus="${i2c_device##*-}"
for alias in 0052 005c; do
	device="${bus}-${alias}"
	driver="/sys/bus/i2c/devices/${device}/driver"
	if [[ -L "$driver" ]]; then
		echo "$device" > "$driver/unbind"
		echo "Unbound ${device}"
	fi
done

dtoverlay -r "$overlay_id"
echo "Removed overlay ${overlay_id}"
