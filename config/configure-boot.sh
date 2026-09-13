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

set_camera_auto_detect_off()
{
	if grep -Eq '^[[:space:]]*camera_auto_detect=1([[:space:]]|$)' "$boot_config"; then
		ensure_backup
		sed -i -E \
			's/^[[:space:]]*camera_auto_detect=1([[:space:]]*)$/camera_auto_detect=0/' \
			"$boot_config"
		printf 'Disabled Raspberry Pi camera auto-detection in %s\n' "$boot_config"
		changed=1
	elif ! grep -Eq '^[[:space:]]*camera_auto_detect=0([[:space:]]|$)' "$boot_config"; then
		ensure_backup
		printf 'camera_auto_detect=0\n' >> "$boot_config"
		printf 'Added camera_auto_detect=0 to %s\n' "$boot_config"
		changed=1
	else
		printf 'camera_auto_detect=0 is already present.\n'
	fi
}

enable_dtparam i2c_arm
enable_dtparam i2c_csi_dsi
set_camera_auto_detect_off

install -D -m 0644 "$script_dir/be-iis-camera-modules.conf" \
	/etc/modules-load.d/be-iis-camera.conf

printf 'Installed /etc/modules-load.d/be-iis-camera.conf\n'

if [[ "$changed" -eq 1 ]]; then
	printf 'Boot configuration changed; reboot required.\n'
	printf 'BE_IIS_REBOOT_REQUIRED=1\n'
else
	printf 'Boot configuration is already correct for the GMSL camera setup.\n'
	printf 'BE_IIS_REBOOT_REQUIRED=0\n'
fi
