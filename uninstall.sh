#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	exec sudo -- "$0" "$@"
fi

readonly SERVICE="be-iis-camera-init.service"
readonly LIBEXEC_DIR="/usr/libexec/be-iis-camera"
readonly PREFIX="/usr/local"

remove_overlay()
{
	local overlay="$1"
	local -a indices=()
	local index

	mapfile -t indices < <(
		dtoverlay -l 2>/dev/null |
			awk -v name="$overlay" '$0 ~ name { gsub(/:/, "", $1); print $1 }' |
			sort -rn
	)

	for index in "${indices[@]}"; do
		dtoverlay -r "$index" 2>/dev/null || true
	done
}

systemctl disable --now "$SERVICE" 2>/dev/null || true
rm -f -- "/etc/systemd/system/$SERVICE"
rm -rf -- "$LIBEXEC_DIR"

# Remove the profile overlays if they were loaded dynamically in this boot.
remove_overlay 'imx708-gmsl-link-b-csi1'
remove_overlay 'imx708-gmsl-link-b-csi0-port-map-test'
remove_overlay '^.*imx708$'

rm -f -- \
	"$PREFIX/bin/beiis-camera-init" \
	"$PREFIX/bin/beiis-ina226-init-alerts" \
	"$PREFIX/bin/beiis-ina226-set-ocp" \
	"$PREFIX/bin/beiis-ina226-set-ovp" \
	"$PREFIX/bin/beiis-ina226-clear-alert" \
	"$PREFIX/bin/beiis-ina226-dump" \
	"$PREFIX/bin/beiis-capture-image" \
	"$PREFIX/bin/beiis-capture-video" \
	"$PREFIX/bin/beiis-gst-preview" \
	"$PREFIX/bin/beiis-gst-record" \
	"$PREFIX/bin/beiis-raw10-to-png"

rm -f -- "/etc/modules-load.d/be-iis-camera.conf"

systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

printf '%s\n' \
	"Removed BE-IIS camera userspace, Link-A/Link-B runtime overlays, and disabled $SERVICE." \
	"The system I2C setting and the kernel IMX708 module are left unchanged."
