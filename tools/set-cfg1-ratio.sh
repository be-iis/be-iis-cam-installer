#!/usr/bin/env bash
set -Eeuo pipefail

readonly POT_ADDRESS="0x51"
readonly ACCESS_CONTROL_REGISTER="0x10"
readonly CHANNEL_B_REGISTER="0x01"
readonly NONVOLATILE_ACCESS="0x40"

usage() {
	cat <<'EOF'
Set CFG1 through channel B of the TPL0102-100 and store it in EEPROM.

Usage:
  set-cfg1-ratio.sh --ratio <value> --i2c-device <bus>

Options:
  --ratio         Ratio specified as 67.95%, 67.95, or 0.6795
  --i2c-device    I2C bus specified as 11, i2c-11, or /dev/i2c-11
  --dry-run       Calculate the value without accessing the I2C bus
  -h, --help      Display this help

Example:
  ./set-cfg1-ratio.sh --ratio 67.95 --i2c-device 11
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

ratio=""
i2c_device=""
dry_run=false

while (($#)); do
	case "$1" in
		--ratio)
			(($# >= 2)) || die "--ratio requires a value"
			ratio="$2"
			shift 2
			;;
		--ratio=*)
			ratio="${1#*=}"
			shift
			;;
		--i2c-device)
			(($# >= 2)) || die "--i2c-device requires a value"
			i2c_device="$2"
			shift 2
			;;
		--i2c-device=*)
			i2c_device="${1#*=}"
			shift
			;;
		--dry-run)
			dry_run=true
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

[[ -n "$ratio" ]] || die "missing required option --ratio"
[[ -n "$i2c_device" ]] || die "missing required option --i2c-device"

bus="$i2c_device"
bus="${bus#/dev/i2c/}"
bus="${bus#/dev/i2c-}"
bus="${bus#i2c-}"
[[ "$bus" =~ ^[0-9]+$ ]] || die "invalid I2C device: $i2c_device"

if ! calculation="$(
	awk -v input="$ratio" '
		BEGIN {
			gsub(/[[:space:]]/, "", input)
			is_percent = sub(/%$/, "", input)

			if (input !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/)
				exit 1

			value = input + 0
			if (is_percent || value > 1)
				fraction = value / 100
			else
				fraction = value

			if (fraction < 0 || fraction > 1)
				exit 1

			code = int(fraction * 256 + 0.5)
			if (code > 255)
				code = 255

			printf "%d %.6f", code, code / 256 * 100
		}
	'
)"; then
	die "invalid ratio '$ratio'; use a value from 0 to 1 or from 0 to 100%"
fi

read -r target_code actual_percent <<<"$calculation"
printf -v target_hex '0x%02x' "$target_code"

printf 'CFG1 target from input %s: code %d (%s), actual ratio %.6f%%\n' \
	"$ratio" "$target_code" "$target_hex" "$actual_percent"

if "$dry_run"; then
	printf 'Dry run: no I2C access performed.\n'
	exit 0
fi

command -v i2ctransfer >/dev/null ||
	die "i2ctransfer is missing; install the i2c-tools package"
[[ -e "/dev/i2c-$bus" ]] ||
	die "/dev/i2c-$bus does not exist"

if ((EUID == 0)); then
	i2c_cmd=(i2ctransfer)
else
	command -v sudo >/dev/null || die "root privileges are required, but sudo is unavailable"
	i2c_cmd=(sudo i2ctransfer)
fi

read_register() {
	local register="$1"
	local result

	result="$("${i2c_cmd[@]}" -f -y "$bus" \
		w1@"$POT_ADDRESS" "$register" r1)"
	[[ "$result" =~ ^0x[0-9a-fA-F]{2}$ ]] ||
		die "unexpected response for register $register: $result"
	printf '%s\n' "$result"
}

write_register() {
	local register="$1"
	local value="$2"

	"${i2c_cmd[@]}" -f -y "$bus" \
		w2@"$POT_ADDRESS" "$register" "$value"
}

acr="$(read_register "$ACCESS_CONTROL_REGISTER")"
printf 'TPL0102 ACR before configuration: %s\n' "$acr"

# VOL=0 selects nonvolatile IVR access while shutdown remains disabled.
if [[ "${acr,,}" != "$NONVOLATILE_ACCESS" ]]; then
	write_register "$ACCESS_CONTROL_REGISTER" "$NONVOLATILE_ACCESS"
fi

current_hex="$(read_register "$CHANNEL_B_REGISTER")"
current_code=$((current_hex))
printf 'Stored CFG1 value: code %d (%s)\n' "$current_code" "$current_hex"

if ((current_code == target_code)); then
	printf 'The stored value is already correct; no EEPROM write is required.\n'
	exit 0
fi

printf 'Writing channel B: %s -> %s ...\n' "$current_hex" "$target_hex"
write_register "$CHANNEL_B_REGISTER" "$target_hex"

# The datasheet specifies a maximum EEPROM write-cycle time of 20 ms.
sleep 0.05

verify_hex="$(read_register "$CHANNEL_B_REGISTER")"
verify_code=$((verify_hex))
if ((verify_code != target_code)); then
	die "verification failed: expected $target_hex, read $verify_hex"
fi

printf 'Successfully stored and verified: %s\n' "$verify_hex"
printf 'Note: The MAX96716A samples CFG1 during power-up. Fully power-cycle the hardware to apply the new setting.\n'
