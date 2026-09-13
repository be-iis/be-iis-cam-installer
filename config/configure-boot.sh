#!/usr/bin/env bash
set -euo pipefail

die()
{
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

[[ "${EUID}" -eq 0 ]] || die "run this script as root"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f /boot/firmware/config.txt ]]; then
	boot_config=/boot/firmware/config.txt
elif [[ -f /boot/config.txt ]]; then
	boot_config=/boot/config.txt
else
	die "Raspberry Pi config.txt was not found"
fi

changed=0
backup=""

ensure_backup()
{
	if [[ -z "$backup" ]]; then
		backup="${boot_config}.be-iis-backup-$(date +%Y%m%d-%H%M%S)"
		cp -a "$boot_config" "$backup"
		printf 'Backup: %s\n' "$backup"
	fi
}

enable_dtparam()
{
	local name="$1"

	if grep -Eq "^[[:space:]]*dtparam=${name}=off([[:space:]]|$)" "$boot_config"; then
		ensure_backup
		sed -i -E \
			"s/^[[:space:]]*dtparam=${name}=off([[:space:]]*)$/dtparam=${name}=on/" \
			"$boot_config"
		printf 'Enabled dtparam=%s=on in %s\n' "$name" "$boot_config"
		changed=1
	elif ! grep -Eq "^[[:space:]]*dtparam=${name}=on([[:space:]]|$)" "$boot_config"; then
		ensure_backup
		printf 'dtparam=%s=on\n' "$name" >> "$boot_config"
		printf 'Added dtparam=%s=on to %s\n' "$name" "$boot_config"
		changed=1
	else
		printf 'dtparam=%s=on is already present.\n' "$name"
	fi
}

enable_dtparam i2c_arm
enable_dtparam i2c_csi_dsi

install -D -m 0644 "$script_dir/be-iis-camera-modules.conf" \
	/etc/modules-load.d/be-iis-camera.conf

printf 'Installed /etc/modules-load.d/be-iis-camera.conf\n'

if [[ "$changed" -eq 1 ]]; then
	printf 'Boot configuration changed; reboot required.\n'
else
	printf 'Boot configuration already contains the required I2C settings.\n'
fi
