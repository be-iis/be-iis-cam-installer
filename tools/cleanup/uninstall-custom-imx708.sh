#!/usr/bin/env bash
# Remove only the BE-IIS out-of-tree IMX708 kernel module installed by install.sh.
set -Eeuo pipefail

(( EUID == 0 )) || {
	printf 'Run with sudo.\n' >&2
	exit 1
}

module_path="/lib/modules/$(uname -r)/updates/imx708.ko"

if [[ -e "$module_path" ]]; then
	rm -f -- "$module_path"
	printf 'Removed: %s\n' "$module_path"
else
	printf 'No custom IMX708 module found at: %s\n' "$module_path"
fi

depmod "$(uname -r)"
printf 'Kernel module dependency database updated. Reboot before testing the camera.\n'
