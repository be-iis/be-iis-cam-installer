#!/usr/bin/env bash
# Activate the known-good Link-A diagnostic profile for the current boot.
# This intentionally installs no systemd service: Link A and Link B are
# mutually exclusive bring-up profiles and must not silently reconfigure each
# other at a later boot.
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
	exec sudo -- "$0" "$@"
fi

if dtoverlay -l 2>/dev/null | grep -q 'imx708-gmsl-link-b'; then
	printf '%s\n' \
		"ERROR: A Link-B overlay is already loaded." \
		"Run ./uninstall.sh and reboot before selecting Link A." >&2
	exit 1
fi

exec bash "$repo_dir/init-imx708-gmsl-port-a-tunnel.sh" init
