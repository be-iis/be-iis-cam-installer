#!/usr/bin/env bash
#
# Manual Link-A I2C initialisation.
#
# Configures only the control path:
#   Pi I2C -> MAX96716A Link A -> MAX96717 -> IMX708
#
# It sets the validated Link-A padding, detects the serializer, provides the
# IMX708 reference clock, releases camera reset and creates the local alias:
#     local 0x52 -> remote IMX708 0x1a
#
# It intentionally does NOT load an overlay, bind a Linux sensor driver,
# configure a CSI/video pipe, or start camera streaming.
#
# Usage:
#   sudo bash tools/init-gmsl-link-a.sh
#
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
PADDING_ADDR="${PADDING_ADDR:-0x51}"
PADDING_VALUE="${PADDING_VALUE:-0xae}"
SENSOR_ALIAS="${SENSOR_ALIAS:-0x52}"
SENSOR_REMOTE="${SENSOR_REMOTE:-0x1a}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

write_reg() {
	local address="$1" reg="$2" value="$3"
	i2ctransfer -f -y "$I2C_BUS" "w3@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" "$value"
}

read_id() {
	local address="$1" reg="$2"
	i2ctransfer -f -y "$I2C_BUS" "w2@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" r2
}

wait_for_serializer() {
	local id="" attempt

	for attempt in {1..30}; do
		id="$(read_id "$SER_ADDR" 000d 2>/dev/null || true)"
		[[ "$id" == "0xbf 0x06" ]] && break
		sleep 0.1
	done

	printf 'MAX96717 Link-A ID/revision: %s\n' "${id:-unavailable}"
	[[ "$id" == "0xbf 0x06" ]] ||
		die "Link-A serializer is not reachable at ${SER_ADDR}."
}

main() {
	local sensor_id

	(( EUID == 0 )) || die 'Run with sudo.'
	command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

	echo '==> Configure Link-A reverse I2C'
	i2ctransfer -f -y "$I2C_BUS" "w2@${PADDING_ADDR}" 0x01 "$PADDING_VALUE"
	write_reg "$DES_ADDR" 0001 0x02
	write_reg "$DES_ADDR" 0011 0x0b
	write_reg "$DES_ADDR" 0010 0x31
	wait_for_serializer

	echo '==> Configure Link-A IMX708 clock, power and reset'
	# Keep serializer video output disabled; this is control-plane setup only.
	write_reg "$SER_ADDR" 0002 0x03
	write_reg "$SER_ADDR" 056f 0x0e
	write_reg "$SER_ADDR" 0003 0x07
	write_reg "$SER_ADDR" 03f0 0x5a
	write_reg "$SER_ADDR" 03f0 0x59
	write_reg "$SER_ADDR" 0006 0xb0

	# IMX708 power enable and XCLR release via MAX96717 GPIO.
	write_reg "$SER_ADDR" 02ca 0x80
	write_reg "$SER_ADDR" 02c7 0x90
	sleep 0.1
	write_reg "$SER_ADDR" 02ca 0x90

	echo '==> Create Link-A IMX708 alias 0x52 -> 0x1a'
	# MAX96717 translation registers store I2C addresses in 8-bit form.
	write_reg "$SER_ADDR" 0042 "$(printf '0x%02x' "$((SENSOR_ALIAS << 1))")"
	write_reg "$SER_ADDR" 0043 "$(printf '0x%02x' "$((SENSOR_REMOTE << 1))")"
	write_reg "$SER_ADDR" 0044 0x00
	write_reg "$SER_ADDR" 0045 0x00

	sleep 0.1
	sensor_id="$(read_id "$SENSOR_ALIAS" 0016 2>/dev/null || true)"
	printf 'IMX708 Link-A via alias 0x%02x: %s\n' \
		"$SENSOR_ALIAS" "${sensor_id:-unavailable}"
	[[ "$sensor_id" == "0x07 0x08" ]] ||
		die 'IMX708 is not reachable through Link-A alias.'
}

main "$@"
