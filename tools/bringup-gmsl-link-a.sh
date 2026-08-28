#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Verified Link-A video sequence.
#
# Prerequisite: make init-a-b
#
# This deliberately configures only Link A:
#   IMX708@0x52 -> MAX96717 -> MAX96716A pipe 0 -> Port A / DPHY0 -> CSI1
# The second I2C translator provides autofocus:
#   DW9807@0x5c -> physical 0x0c
#
# Link B is not changed by this script.
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
SENSOR_ALIAS="${SENSOR_ALIAS:-0x52}"
FOCUS_ALIAS="${FOCUS_ALIAS:-0x5c}"

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

main() {
	(( EUID == 0 )) || die 'Run with sudo.'
	command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
	[[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

	echo '==> Select Link A for video and reverse I2C'
	# These are the verified Link-A values. Do not use the old 0x0001/0x0011 writes.
	write_reg "$DES_ADDR" 0f00 0x01
	write_reg "$DES_ADDR" 0010 0x31
	write_reg "$DES_ADDR" 0012 0x20
	sleep 0.2

	[[ "$(read_id "$SER_ADDR" 000d)" == '0xbf 0x06' ]] ||
		die 'Link-A serializer is not reachable.'

	echo '==> Configure Link-A autofocus alias'
	# Second MAX96717 I2C translator: local 0x5c -> remote DW9807 0x0c.
	write_reg "$SER_ADDR" 0044 0xb8
	write_reg "$SER_ADDR" 0045 0x18
	printf 'DW9807 Link-A status: '
	i2ctransfer -f -y "$I2C_BUS" "w1@${FOCUS_ALIAS}" 0x05 r1

	echo '==> Configure MAX96717 Link-A CSI input and tunnel'
	write_reg "$SER_ADDR" 0002 0x03
	write_reg "$SER_ADDR" 0308 0x64
	write_reg "$SER_ADDR" 0311 0x40
	write_reg "$SER_ADDR" 0330 0x40
	write_reg "$SER_ADDR" 0331 0x10
	write_reg "$SER_ADDR" 0332 0xe0
	write_reg "$SER_ADDR" 0333 0x04
	write_reg "$SER_ADDR" 0334 0x00
	write_reg "$SER_ADDR" 0335 0x00
	write_reg "$SER_ADDR" 0383 0x80
	write_reg "$SER_ADDR" 005b 0x00
	write_reg "$SER_ADDR" 0002 0x43

	echo '==> Configure MAX96716A pipe 0 to Port A / DPHY0'
	write_reg "$DES_ADDR" 0313 0x00
	write_reg "$DES_ADDR" 0160 0x01
	write_reg "$DES_ADDR" 0161 0x20
	write_reg "$DES_ADDR" 0308 0x01
	write_reg "$DES_ADDR" 031d 0x2f
	write_reg "$DES_ADDR" 0320 0x29
	write_reg "$DES_ADDR" 0330 0x04
	write_reg "$DES_ADDR" 0332 0xf4
	write_reg "$DES_ADDR" 0333 0x4e
	write_reg "$DES_ADDR" 0334 0xe4
	write_reg "$DES_ADDR" 0335 0x00
	write_reg "$DES_ADDR" 0336 0x00
	write_reg "$DES_ADDR" 0440 0x01
	write_reg "$DES_ADDR" 0443 0x01
	write_reg "$DES_ADDR" 0444 0x01
	write_reg "$DES_ADDR" 0445 0x71
	write_reg "$DES_ADDR" 0446 0x19
	write_reg "$DES_ADDR" 0447 0x1c
	write_reg "$DES_ADDR" 0449 0x01
	write_reg "$DES_ADDR" 044a 0x50
	write_reg "$DES_ADDR" 0474 0x09
	write_reg "$DES_ADDR" 1d00 0xf4
	sleep 0.02
	write_reg "$DES_ADDR" 1d00 0xf5
	write_reg "$DES_ADDR" 0313 0x02

	echo '==> Link-A video configuration complete'
	printf 'IMX708 Link-A: '
	read_id "$SENSOR_ALIAS" 0016
	printf 'MAX96716A pipe: '
	read_reg "$DES_ADDR" 0160
	printf 'MAX96717 CSI input: '
	read_reg "$SER_ADDR" 0383
}

main "$@"
