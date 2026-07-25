#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_PATCH_DIR="${SCRIPT_DIR}/patches"
readonly DEFAULT_KERNEL_IMAGE="kernel_2712_gmsl.img"
readonly DEFAULT_DEVICE_TREE="bcm2712-rpi-5-b-gmsl.dtb"
readonly DEFAULT_INITRAMFS="initramfs_2712_gmsl"

usage() {
	cat <<'EOF'
Build and install the ADI GMSL kernel for Raspberry Pi 5.

Usage:
  build-install-kernel.sh --adi-linux-dir <path> [options]

Options:
  --adi-linux-dir  ADI Linux source tree using branch gmsl/rpi-6.13.y
  --jobs           Parallel build jobs (default: number of CPUs)
  --skip-build     Install an already completed kernel build
  --no-patches     Do not apply the bundled IMX708 robustness patch
  --no-initramfs   Do not create a dedicated initramfs
  -h, --help       Display this help

The script installs dedicated GMSL boot files and does not modify config.txt.
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 ||
		die "required command not found: $1"
}

adi_linux_dir="${ADI_LINUX_DIR:-}"
jobs="$(nproc)"
skip_build=false
apply_patches=true
create_initramfs=true

while (($#)); do
	case "$1" in
		--adi-linux-dir)
			(($# >= 2)) || die "--adi-linux-dir requires a value"
			adi_linux_dir="$2"
			shift 2
			;;
		--adi-linux-dir=*)
			adi_linux_dir="${1#*=}"
			shift
			;;
		--jobs)
			(($# >= 2)) || die "--jobs requires a value"
			jobs="$2"
			shift 2
			;;
		--jobs=*)
			jobs="${1#*=}"
			shift
			;;
		--skip-build)
			skip_build=true
			shift
			;;
		--no-patches)
			apply_patches=false
			shift
			;;
		--no-initramfs)
			create_initramfs=false
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

for command_name in make gcc bc bison flex perl openssl rsync patch sudo nproc; do
	require_command "$command_name"
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] ||
	die "--jobs must be a positive integer"
[[ -n "$adi_linux_dir" ]] ||
	die "missing --adi-linux-dir (or set ADI_LINUX_DIR)"
[[ -d "$adi_linux_dir" ]] ||
	die "ADI Linux source directory not found: $adi_linux_dir"

adi_linux_dir="$(cd -- "$adi_linux_dir" && pwd)"
config_target="bcm2712_adi_gmsl_defconfig"
kernel_image="${adi_linux_dir}/arch/arm64/boot/Image"
device_tree="${adi_linux_dir}/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dtb"
imx708_source="${adi_linux_dir}/drivers/media/i2c/imx708.c"

[[ -f "${adi_linux_dir}/Makefile" ]] ||
	die "Linux kernel Makefile not found in: $adi_linux_dir"
[[ -f "${adi_linux_dir}/arch/arm64/configs/${config_target}" ]] ||
	die "ADI Raspberry Pi GMSL defconfig not found: $config_target"
[[ -f "$imx708_source" ]] ||
	die "IMX708 driver source not found: $imx708_source"

if "$apply_patches"; then
	patch_file="${DEFAULT_PATCH_DIR}/0001-media-imx708-handle-reset-gpio-errors.patch"
	[[ -f "$patch_file" ]] ||
		die "bundled kernel patch not found: $patch_file"

	if grep -A8 'reset_gpio = devm_gpiod_get_optional' "$imx708_source" |
		grep -q 'IS_ERR(imx708->reset_gpio)'; then
		printf 'Kernel patch already present: %s\n' "$(basename -- "$patch_file")"
	else
		printf 'Applying kernel patch: %s\n' "$(basename -- "$patch_file")"
		patch --batch --forward -d "$adi_linux_dir" -p1 <"$patch_file"
	fi
fi

if ! "$skip_build"; then
	printf 'Configuring the ADI GMSL kernel\n'
	make -C "$adi_linux_dir" ARCH=arm64 "$config_target"

	"${adi_linux_dir}/scripts/config" --file "${adi_linux_dir}/.config" \
		--module VIDEO_MAXIM_SERDES \
		--module VIDEO_MAX9296A \
		--module VIDEO_MAX96717 \
		--module VIDEO_IMX708

	make -C "$adi_linux_dir" ARCH=arm64 olddefconfig

	printf 'Building Image, modules and Device Trees with %s jobs\n' "$jobs"
	make -C "$adi_linux_dir" -j"$jobs" ARCH=arm64 Image modules dtbs
fi

[[ -s "$kernel_image" ]] ||
	die "kernel Image is missing; complete the build first"
[[ -s "$device_tree" ]] ||
	die "Raspberry Pi 5 Device Tree is missing; complete the build first"

kernel_release="$(make -s -C "$adi_linux_dir" ARCH=arm64 kernelrelease)"
[[ -n "$kernel_release" ]] ||
	die "could not determine the kernel release"

printf 'Installing modules for %s\n' "$kernel_release"
sudo make -C "$adi_linux_dir" ARCH=arm64 modules_install
sudo depmod "$kernel_release"

if [[ -d /boot/firmware/overlays ]]; then
	boot_dir="/boot/firmware"
	config_file="/boot/firmware/config.txt"
elif [[ -d /boot/overlays ]]; then
	boot_dir="/boot"
	config_file="/boot/config.txt"
else
	die "Raspberry Pi boot directory not found"
fi

installed_kernel="${boot_dir}/${DEFAULT_KERNEL_IMAGE}"
installed_dtb="${boot_dir}/${DEFAULT_DEVICE_TREE}"
installed_initramfs="${boot_dir}/${DEFAULT_INITRAMFS}"

printf 'Installing dedicated kernel image: %s\n' "$installed_kernel"
sudo install -m 0644 "$kernel_image" "$installed_kernel"

printf 'Installing dedicated Device Tree: %s\n' "$installed_dtb"
sudo install -m 0644 "$device_tree" "$installed_dtb"

if "$create_initramfs"; then
	require_command mkinitramfs
	printf 'Creating dedicated initramfs: %s\n' "$installed_initramfs"
	tmp_initramfs="$(mktemp)"
	cleanup() {
		rm -f -- "${tmp_initramfs:-}"
	}
	trap cleanup EXIT
	sudo mkinitramfs -o "$tmp_initramfs" "$kernel_release"
	sudo install -m 0644 "$tmp_initramfs" "$installed_initramfs"
fi

printf '\nADI GMSL kernel installation completed.\n'
printf 'Kernel release: %s\n' "$kernel_release"
printf 'Add these lines below [all] in %s:\n' "$config_file"
printf '  kernel=%s\n' "$DEFAULT_KERNEL_IMAGE"
printf '  device_tree=%s\n' "$DEFAULT_DEVICE_TREE"
if "$create_initramfs"; then
	printf '  initramfs %s followkernel\n' "$DEFAULT_INITRAMFS"
fi
printf '\nDo not reboot until the matching camera overlay is installed.\n'
