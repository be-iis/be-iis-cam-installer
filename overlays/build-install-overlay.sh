#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_OVERLAY_NAME="max96716a-max96717-imx708-be-iis"
readonly DEFAULT_PROFILE="${SCRIPT_DIR}/profiles/${DEFAULT_OVERLAY_NAME}.json"
readonly CAMERA_TEMPLATE="${SCRIPT_DIR}/templates/imx708-be-iis.dtsi.in"

usage() {
	cat <<'EOF'
Generate, build and install the BE-IIS MAX96716A Device Tree overlay.

Usage:
  build-install-overlay.sh --adi-linux-dir <path> [options]

Options:
  --adi-linux-dir  ADI Linux source tree using branch gmsl/rpi-6.13.y
  --profile        Generator JSON profile (default: bundled BE-IIS profile)
  --output-dir     Generated-file directory (default: overlays/build)
  --no-install     Do not install the resulting DTBO into /boot
  -h, --help       Display this help
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
profile="$DEFAULT_PROFILE"
output_dir="${SCRIPT_DIR}/build"
install=true

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
		--profile)
			(($# >= 2)) || die "--profile requires a value"
			profile="$2"
			shift 2
			;;
		--profile=*)
			profile="${1#*=}"
			shift
			;;
		--output-dir)
			(($# >= 2)) || die "--output-dir requires a value"
			output_dir="$2"
			shift 2
			;;
		--output-dir=*)
			output_dir="${1#*=}"
			shift
			;;
		--no-install)
			install=false
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

require_command python3
require_command dtc
require_command mktemp
require_command cp
require_command grep
python3 -c 'import jinja2' >/dev/null 2>&1 ||
	die "Python module jinja2 is missing; install it with: sudo apt install python3-jinja2"

[[ -n "$adi_linux_dir" ]] ||
	die "missing --adi-linux-dir (or set ADI_LINUX_DIR)"
[[ -d "$adi_linux_dir" ]] ||
	die "ADI Linux source directory not found: $adi_linux_dir"
[[ -f "$profile" ]] ||
	die "generator profile not found: $profile"
[[ -f "$CAMERA_TEMPLATE" ]] ||
	die "board-specific camera template not found: $CAMERA_TEMPLATE"

generator_dir="${adi_linux_dir%/}/arch/arm/boot/dts/overlays/gen_gmsl_dts"
generator="${generator_dir}/gen_gmsl_dts.py"
driver="${adi_linux_dir%/}/drivers/media/i2c/maxim-serdes/max9296a.c"

[[ -f "$generator" ]] ||
	die "ADI GMSL Device Tree generator not found: $generator"
[[ -f "$driver" ]] ||
	die "MAX96716A driver source not found: $driver"
grep -q 'maxim,max96716a' "$driver" ||
	die "the selected ADI source tree does not contain MAX96716A support"

mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
profile="$(cd -- "$(dirname -- "$profile")" && pwd)/$(basename -- "$profile")"
overlay_name="$(basename -- "$profile" .json)"
generated_dts="${output_dir}/${overlay_name}.dts"
generated_dtbo="${output_dir}/${overlay_name}.dtbo"

generator_work_dir="$(mktemp -d)"
cleanup() {
	[[ -n "${generator_work_dir:-}" ]] || return 0
	[[ -d "$generator_work_dir" ]] || return 0
	rm -rf -- "$generator_work_dir"
}
trap cleanup EXIT

cp -a "${generator_dir}/." "$generator_work_dir/"
cp "$CAMERA_TEMPLATE" "$generator_work_dir/imx708-be-iis.dtsi.in"
cp "$profile" "$generator_work_dir/profile.json"

printf 'Generating %s\n' "$generated_dts"
(
	cd -- "$generator_work_dir"
	python3 ./gen_gmsl_dts.py ./profile.json --dtbo --o "$generated_dts"
)

[[ -s "$generated_dts" ]] ||
	die "ADI generator did not create a non-empty DTS file"
grep -q 'pins = "mfp2";' "$generated_dts" ||
	die "generated DTS does not route MAX96717 RCLKOUT to MFP2"
if grep -q 'groups = "mfp2";' "$generated_dts"; then
	die "generated DTS contains the unsupported MAX96717 groups property"
fi
grep -q 'reset-gpios = .* 4 0>;' "$generated_dts" ||
	die "generated DTS does not route IMX708 XCLR to MAX96717 MFP4"
if [[ "$profile" == "$DEFAULT_PROFILE" ]]; then
	grep -q 'lens-focus' "$generated_dts" ||
		die "generated DTS does not connect the IMX708 to its focus actuator"
	grep -q 'dw9817@c' "$generated_dts" ||
		die "generated DTS does not enable the DW9817 VCM at 0x0c"
	grep -q 'compatible = "dongwoon,dw9817-vcm";' "$generated_dts" ||
		die "generated DTS does not use the DW9817 VCM binding"
	grep -q 'i2c-alias-pool = <0x52 0x53>;' "$generated_dts" ||
		die "generated DTS does not use the collision-free remote I2C alias pool"
fi

printf 'Compiling %s\n' "$generated_dtbo"
dtc -@ -H epapr -I dts -O dtb -o "$generated_dtbo" "$generated_dts"
[[ -s "$generated_dtbo" ]] ||
	die "Device Tree compiler did not create a non-empty DTBO file"

if "$install"; then
	require_command sudo

	if [[ -d /boot/firmware/overlays ]]; then
		overlay_dir="/boot/firmware/overlays"
		config_file="/boot/firmware/config.txt"
	elif [[ -d /boot/overlays ]]; then
		overlay_dir="/boot/overlays"
		config_file="/boot/config.txt"
	else
		die "Raspberry Pi overlay directory not found"
	fi

	install_path="${overlay_dir}/${overlay_name}.dtbo"
	printf 'Installing %s\n' "$install_path"
	sudo install -m 0644 "$generated_dtbo" "$install_path"
fi

printf '\nOverlay build completed successfully.\n'
printf 'Generated DTBO: %s\n' "$generated_dtbo"
if "$install"; then
	printf 'Installed DTBO: %s\n' "$install_path"
	printf 'Add this line to %s:\n' "$config_file"
	printf '  dtoverlay=%s\n' "$overlay_name"
	printf 'Then reboot into the ADI GMSL kernel.\n'
fi
