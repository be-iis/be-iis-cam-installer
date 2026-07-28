#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
	exec sudo -- "$0" "$@"
fi

readonly SERVICE="be-iis-camera-init.service"
readonly LIBEXEC_DIR="/usr/libexec/be-iis-camera"
readonly PREFIX="/usr/local"

systemctl disable --now "$SERVICE" 2>/dev/null || true
rm -f -- "/etc/systemd/system/$SERVICE"
rm -rf -- "$LIBEXEC_DIR"

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
	"Removed BE-IIS camera userspace and disabled $SERVICE." \
	"Left kernel modules, installed driver artifacts, and dtparam=i2c_arm=on unchanged."
