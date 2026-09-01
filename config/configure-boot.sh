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

if grep -Eq '^[[:space:]]*dtparam=i2c_arm=off([[:space:]]|$)' "$boot_config"; then
	backup="${boot_config}.be-iis-backup-$(date +%Y%m%d-%H%M%S)"
	cp -a "$boot_config" "$backup"
	sed -i -E \
		's/^[[:space:]]*dtparam=i2c_arm=off([[:space:]]*)$/dtparam=i2c_arm=on/' \
		"$boot_config"
	printf 'Backup: %s\n' "$backup"
	changed=1
elif ! grep -Eq '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "$boot_config"; then
	backup="${boot_config}.be-iis-backup-$(date +%Y%m%d-%H%M%S)"
	cp -a "$boot_config" "$backup"
	{
		printf '\n# BE-IIS camera support\n'
		printf 'dtparam=i2c_arm=on\n'
	} >> "$boot_config"
	printf 'Backup: %s\n' "$backup"
	changed=1
fi


install -D -m 0644 "$script_dir/be-iis-camera-modules.conf" \
	/etc/modules-load.d/be-iis-camera.conf

if [[ "$changed" -eq 1 ]]; then
	printf 'Enabled I2C in %s\n' "$boot_config"
else
	printf 'I2C is already enabled in %s\n' "$boot_config"
fi

printf 'Installed /etc/modules-load.d/be-iis-camera.conf\n'
printf 'No reboot was performed.\n'
