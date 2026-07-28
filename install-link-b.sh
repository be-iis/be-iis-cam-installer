#!/usr/bin/env bash
# Activate the Link-B / CSI1 diagnostic profile for the current boot.
# Link B is currently a hardware bring-up profile: it configures the proven
# GMSL path and loads the IMX708 node on I2C-11/CSI1, but it cannot compensate
# for the unresolved DPHY1-to-CSI1 physical failure.
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$repo_dir/overlays"
overlay_name="imx708-gmsl-link-b-csi1"
overlay_file="$overlay_dir/build/${overlay_name}.dtbo"

if [[ "${EUID}" -ne 0 ]]; then
	exec sudo -- "$0" "$@"
fi

command -v dtc >/dev/null || {
	printf '%s\n' 'ERROR: device-tree-compiler (dtc) is required.' >&2
	exit 1
}

if dtoverlay -l 2>/dev/null | grep -qE '(^|[[:space:]])imx708([[:space:]]|$)|imx708-gmsl-link-b-csi0'; then
	printf '%s\n' \
		"ERROR: An incompatible IMX708 overlay is already loaded." \
		"Run ./uninstall.sh and reboot before selecting Link B." >&2
	exit 1
fi

bash "$repo_dir/init-imx708-gmsl-port-b-tunnel.sh" init

mkdir -p "$overlay_dir/build"
dtc -@ -H epapr -I dts -O dtb \
	-o "$overlay_file" \
	"$overlay_dir/${overlay_name}-overlay.dts"

modprobe imx708

if ! dtoverlay -l 2>/dev/null | grep -q "$overlay_name"; then
	dtoverlay -d "$overlay_dir/build" "$overlay_name"
fi

printf '%s\n' \
	"Link-B diagnostic profile is active for this boot." \
	"Known state: GMSL path works; the DPHY1-to-CSI1 hardware path remains unresolved."
