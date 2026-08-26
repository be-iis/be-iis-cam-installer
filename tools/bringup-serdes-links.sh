#!/usr/bin/env bash
#
# Minimal, manual GMSL control-channel bring-up.
#
# Scope: Raspberry Pi I2C -> MAX96716A -> MAX96717 on Link A and/or Link B.
#
# Deliberately NOT performed:
#   - no IMX708 power, reset or clock configuration
#   - no sensor I2C alias
#   - no MAX96717 CSI input or video pipe configuration
#   - no MAX96716A CSI output / pipe routing
#   - no Device Tree overlay or media graph changes
#
# This is the first debug step after a reboot: it proves that each GMSL
# control channel reaches its serializer before any camera configuration.
#
# Usage:
#   sudo bash tools/bringup-serdes-links.sh
#   sudo bash tools/bringup-serdes-links.sh link-a
#   sudo bash tools/bringup-serdes-links.sh link-b
#
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
LINK_A_PADDING_ADDR="${LINK_A_PADDING_ADDR:-0x51}"
LINK_A_PADDING="${LINK_A_PADDING:-0xae}"

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

read_serializer_id() {
	i2ctransfer -f -y "$I2C_BUS" "w2@${SER_ADDR}" 0x00 0x0d r2
}

wait_for_serializer() {
	local link_name="$1" id="" attempt

	for attempt in {1..30}; do
		id="$(read_serializer_id 2>/dev/null || true)"
		[[ "$id" == "0xbf 0x06" ]] && break
		sleep 0.1
	done

	printf 'MAX96717 %s ID/revision: %s\n' "$link_name" "${id:-unavailable}"
	[[ "$id" == "0xbf 0x06" ]] ||
		die "Link ${link_name}: serializer is not reachable at ${SER_ADDR}."
}

bringup_link_a() {
	echo
	echo '==> Link A: select reverse I2C control channel'

	# Known Link-A padding. This establishes the GMSL link only; it does
	# not power or configure the image sensor.
	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${LINK_A_PADDING_ADDR}" 0x01 "$LINK_A_PADDING"

	# Select Link A and make its remote serializer visible at SER_ADDR.
	write_reg "$DES_ADDR" 0001 0x02
	write_reg "$DES_ADDR" 0011 0x0b
	write_reg "$DES_ADDR" 0010 0x31

	wait_for_serializer A
	printf 'MAX96716A Link-A status: '
	read_reg "$DES_ADDR" 0013
}

bringup_link_b() {
	echo
	echo '==> Link B: select reverse I2C control channel'

	# Minimal validated Link-B selection. It does not configure an IMX708
	# and does not start a video stream.
	write_reg "$DES_ADDR" 0004 0x02
	write_reg "$DES_ADDR" 0011 0x0f
	write_reg "$DES_ADDR" 0013 0x01
	sleep 0.1
	write_reg "$DES_ADDR" 0013 0x00

	wait_for_serializer B
	printf 'MAX96716A Link-B status: '
	read_reg "$DES_ADDR" 5009
}

main() {
	local target="${1:-both}"

	(( EUID == 0 )) || die 'Run with sudo.'
	command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

	case "$target" in
		link-a) bringup_link_a ;;
		link-b) bringup_link_b ;;
		both) bringup_link_a; bringup_link_b ;;
		*) die 'Usage: bringup-serdes-links.sh [link-a|link-b|both]' ;;
	esac
}

main "$@"
