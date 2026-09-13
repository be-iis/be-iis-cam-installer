#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '==> BE-IIS camera installer\n'

printf '\n==> Check Raspberry Pi boot configuration\n'
boot_output="$(sudo bash "$repo_dir/config/configure-boot.sh")"
printf '%s\n' "$boot_output"

if grep -q '^BE_IIS_REBOOT_REQUIRED=1$' <<<"$boot_output"; then
	printf '\nThe Raspberry Pi boot configuration was changed.\n'
	printf 'Required settings include:\n'
	printf '  dtparam=i2c_csi_dsi=on\n'
	printf '  camera_auto_detect=0\n'
	printf '\nA reboot is required before installation can continue.\n'
	printf 'Rebooting now. Run ./install.sh again after the Pi is back.\n'
	sudo reboot
	exit 0
fi

sudo modprobe i2c-dev || true

if [[ ! -e /dev/i2c-11 ]]; then
	printf '\nERROR: boot configuration is correct, but /dev/i2c-11 is still unavailable.\n' >&2
	printf 'Check the Raspberry Pi model, kernel and Device Tree configuration.\n' >&2
	exit 1
fi

printf 'Camera I2C bus found: /dev/i2c-11\n'

printf '\n==> Install required packages\n'
sudo apt-get update
sudo apt-get install -y \
	build-essential \
	raspberrypi-kernel-headers \
	i2c-tools \
	v4l-utils \
	device-tree-compiler \
	rpicam-apps \
	python3-gi \
	python3-gst-1.0 \
	gstreamer1.0-tools \
	gstreamer1.0-plugins-base \
	gstreamer1.0-plugins-good \
	gstreamer1.0-plugins-bad

printf '\n==> Build and install patched IMX708 driver\n'
make -C "$repo_dir" driver

printf '\n==> Build and install MAX96716A I2C mux driver\n'
make -C "$repo_dir" i2c-mux-driver

printf '\nInstallation complete.\n'
printf 'No GMSL link or video pipeline was initialised.\n'
printf 'Use make init-a, make init-b or make init-a-b when you are ready.\n'
