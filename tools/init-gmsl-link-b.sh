#!/usr/bin/env bash
#
# Manual Link-B I2C initialisation.
#
# Configures only MAX96716A Link B for 6 Gbit/s / Coax / Tunnel,
# selects physical Link B, then configures the remote MAX96717 and IMX708 alias.
#
# No DigiPot handling is performed here. Legacy DigiPot hardware can be
# configured separately with tools/set-gmsl-digipot.sh.
#
# No overlay, Linux camera driver, CSI/video stream, or media graph is configured.
#
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
SENSOR_ALIAS="${SENSOR_ALIAS:-0x53}"
SENSOR_REMOTE="${SENSOR_REMOTE:-0x1a}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
	local address="$1" reg="$2"
	i2ctransfer -f -y "$I2C_BUS" "w2@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" r2
}

update_reg_bits() {
	local reg="$1" mask="$2" value="$3"
	local current_hex current next

	current_hex="$(read_reg "$DES_ADDR" "$reg")"
	current=$((current_hex))
	next=$(((current & ~mask) | (value & mask)))
	write_reg "$DES_ADDR" "$reg" "$(printf '0x%02x' "$next")"
}

rate_name() {
	case $(($1 & 0x03)) in
		1) printf '3 Gbit/s' ;;
		2) printf '6 Gbit/s' ;;
		*) printf 'unknown' ;;
	esac
}

cable_name() {
	if (( $1 & 0x04 )); then
		printf 'Coax'
	else
		printf 'Twisted Pair / STP'
	fi
}

mode_name() {
	if (( $1 & 0x01 )); then
		printf 'Tunnel'
	else
		printf 'Pixel'
	fi
}

print_des_state() {
	local prefix="$1"
	local rate_hex cable_hex mode_hex
	local rate cable mode

	rate_hex="$(read_reg "$DES_ADDR" 0004)"
	cable_hex="$(read_reg "$DES_ADDR" 0011)"
	mode_hex="$(read_reg "$DES_ADDR" 04b4)"

	rate=$((rate_hex))
	cable=$((cable_hex))
	mode=$((mode_hex))

	printf '%s Link B: %s | %s | %s  [0x0004=%s 0x0011=%s 0x04b4=%s]\n' \
		"$prefix" "$(rate_name "$rate")" "$(cable_name "$cable")" \
		"$(mode_name "$mode")" "$rate_hex" "$cable_hex" "$mode_hex"
}

wait_for_serializer() {
	local id="" attempt
	for attempt in {1..30}; do
		id="$(read_id "$SER_ADDR" 000d 2>/dev/null || true)"
		[[ "$id" == "0xbf 0x06" ]] && break
		sleep 0.1
	done
	printf 'MAX96717 Link-B ID/revision: %s\n' "${id:-unavailable}"
	[[ "$id" == "0xbf 0x06" ]] ||
		die "Link-B serializer is not reachable at ${SER_ADDR}."
}

main() {
	local sensor_id

	(( EUID == 0 )) || die 'Run with sudo.'
	command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

	echo '==> Configure MAX96716A Link B'
	print_des_state 'ALT:'
	update_reg_bits 0004 0x03 0x02   # Link B: 6 Gbit/s
	update_reg_bits 0011 0x04 0x04   # Link B: Coax
	update_reg_bits 04b4 0x01 0x01   # Pipe B/Z: Tunnel
	update_reg_bits 0f00 0x03 0x02   # Enable/select Link B
	update_reg_bits 0010 0x33 0x32   # AUTO_LINK + Link B + one-shot reset
	sleep 0.2
	print_des_state 'NEU:'

	wait_for_serializer

	echo '==> Configure Link-B IMX708 clock, power and reset'
	write_reg "$SER_ADDR" 0002 0x03
	write_reg "$SER_ADDR" 056f 0x0e
	write_reg "$SER_ADDR" 0003 0x07
	write_reg "$SER_ADDR" 03f0 0x5a
	write_reg "$SER_ADDR" 03f0 0x59
	write_reg "$SER_ADDR" 0006 0xb0
	write_reg "$SER_ADDR" 02ca 0x80
	write_reg "$SER_ADDR" 02c7 0x90
	sleep 0.1
	write_reg "$SER_ADDR" 02ca 0x90

	echo '==> Create Link-B IMX708 alias 0x53 -> 0x1a'
	write_reg "$SER_ADDR" 0042 "$(printf '0x%02x' "$((SENSOR_ALIAS << 1))")"
	write_reg "$SER_ADDR" 0043 "$(printf '0x%02x' "$((SENSOR_REMOTE << 1))")"
	write_reg "$SER_ADDR" 0044 0x00
	write_reg "$SER_ADDR" 0045 0x00

	sleep 0.1
	sensor_id="$(read_id "$SENSOR_ALIAS" 0016 2>/dev/null || true)"
	printf 'IMX708 Link-B via alias 0x%02x: %s\n' \
		"$SENSOR_ALIAS" "${sensor_id:-unavailable}"
	[[ "$sensor_id" == "0x07 0x08" ]] ||
		die 'IMX708 is not reachable through Link-B alias.'
}

main "$@"
