#!/usr/bin/env bash
#
# Prepare and validate:
#   IMX708 -> MAX96717 -> GMSL2 Link B (6 Gbit/s)
#          -> MAX96716A DPHY1 -> Raspberry Pi 5 CSI1
#
# This script deliberately configures only the proven Link-B electrical and
# remote-I2C bring-up. The ADI GMSL overlay configures the CSI/video topology.
#
# Usage:
#   sudo ./init-imx708-gmsl-port-b-tunnel.sh [status]
#
# Expected successful result:
#   Link-B status contains bit 3 (for example 0xc8)
#   MAX96717 ID/revision: 0xbf 0x06
#   IMX708 ID/revision:   0x07 0x08

set -Eeuo pipefail

readonly I2C_BUS="${I2C_BUS:-11}"
readonly DES_ADDR="${DES_ADDR:-0x28}"
readonly SER_ADDR="${SER_ADDR:-0x40}"
readonly POT_ADDR="${POT_ADDR:-0x51}"
readonly SENSOR_ADDR="${SENSOR_ADDR:-0x1a}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

write_reg() {
	local address="$1" reg="$2" value="$3"

	i2ctransfer -f -y "$I2C_BUS" "w3@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" "$value"
}

read_reg() {
	local address="$1" reg="$2"

	i2ctransfer -f -y "$I2C_BUS" "w2@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" r1
}

read_id() {
	local address="$1"

	i2ctransfer -f -y "$I2C_BUS" "w2@${address}" 0x00 0x0d r2
}

check_link_b_lock() {
	local status status_value

	status="$(read_reg "$DES_ADDR" 5009)"
	status_value=$((status))

	printf 'MAX96716A Link-B status: %s\n' "$status"
	(( status_value & 0x08 )) ||
		die "Link B is not locked (bit 3 in 0x5009 is clear)."

	printf 'MAX96717 ID/revision:    '
	read_id "$SER_ADDR"
}

configure_link_b() {
	local serializer_id="" attempt

	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] ||
		die "/dev/i2c-${I2C_BUS} does not exist."

	# TPL0102 channel A belongs to Link B. Channel B remains Link A.
	i2ctransfer -f -y "$I2C_BUS" "w2@${POT_ADDR}" 0x00 0xae

	# RX_RATE_B = 6 Gbit/s; CXTP_B = coax.
	write_reg "$DES_ADDR" 0004 0x02
	write_reg "$DES_ADDR" 0011 0x0f

	# Reset and release only Link B.
	write_reg "$DES_ADDR" 0013 0x01
	sleep 0.1
	write_reg "$DES_ADDR" 0013 0x00

	for attempt in {1..30}; do
		sleep 0.1
		serializer_id="$(read_id "$SER_ADDR" 2>/dev/null || true)"
		[[ "$serializer_id" == "0xbf 0x06" ]] && break
	done

	check_link_b_lock
	[[ "$serializer_id" == "0xbf 0x06" ]] ||
		die "MAX96717 on Link B did not become reachable."
}

enable_camera_and_probe() {
	printf 'Configuring Link-B MAX96717 clock, power and reset\n'

	# Same MAX96717 clock and CSI receiver baseline as the working Link-A path.
	write_reg "$SER_ADDR" 0002 0x03
	write_reg "$SER_ADDR" 056f 0x0e
	write_reg "$SER_ADDR" 0003 0x07
	write_reg "$SER_ADDR" 03f0 0x5a
	write_reg "$SER_ADDR" 03f0 0x59
	write_reg "$SER_ADDR" 0006 0xb0

	# Preserve the IMX708 I2C address through the MAX96717 tunnel.
	write_reg "$SER_ADDR" 0042 0xa4
	write_reg "$SER_ADDR" 0043 0x34
	write_reg "$SER_ADDR" 0044 0x00
	write_reg "$SER_ADDR" 0045 0x00

	write_reg "$SER_ADDR" 02ca 0x80
	write_reg "$SER_ADDR" 02c7 0x90
	sleep 0.1
	write_reg "$SER_ADDR" 02ca 0x90

	# Re-enable pipe 0 before accessing the remote camera I2C bus.
	write_reg "$SER_ADDR" 0002 0x43

	printf 'IMX708 ID/revision:      '
	i2ctransfer -f -y "$I2C_BUS" "w2@${SENSOR_ADDR}" 0x00 0x16 r2
}

main() {
	(( EUID == 0 )) || die "Run this script with sudo."
	command -v i2ctransfer >/dev/null || die "i2ctransfer is required."

	configure_link_b
	enable_camera_and_probe

	printf '\nLink B and the remote IMX708 are ready.\n'
	printf 'Use the dual-CSI overlay profile for CSI1:\n'
	printf '  overlays/profiles/max96716a-max96717-imx708-be-iis-dual-csi.json\n'
}

main "$@"
