#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Optional legacy CFG1 DigiPot setup.
#
# Newer serializer hardware uses a fixed CFG1 resistor network and does not
# require this script. If no DigiPot is found at 0x51, the script exits cleanly.
#
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
POT_ADDR="${POT_ADDR:-0x51}"
POT_REG="${POT_REG:-0x01}"
POT_VALUE="${POT_VALUE:-0xae}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die 'Run with sudo.'
command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
modprobe i2c-dev
[[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

echo "==> Probe legacy CFG1 DigiPot at ${POT_ADDR}"
old_value="$(
	i2ctransfer -f -y "$I2C_BUS" "w1@${POT_ADDR}" "$POT_REG" r1 2>/dev/null || true
)"

if [[ -z "$old_value" ]]; then
	echo "No DigiPot found at ${POT_ADDR}. Nothing to do."
	exit 0
fi

echo "Old value: ${old_value}"
echo "Target:    ${POT_VALUE}"

if [[ "$old_value" == "$POT_VALUE" ]]; then
	echo 'DigiPot already has the requested value.'
	exit 0
fi

echo "==> Set DigiPot to ${POT_VALUE}"
i2ctransfer -f -y "$I2C_BUS" "w2@${POT_ADDR}" "$POT_REG" "$POT_VALUE"

new_value="$(
	i2ctransfer -f -y "$I2C_BUS" "w1@${POT_ADDR}" "$POT_REG" r1
)"

echo "New value: ${new_value}"
[[ "$new_value" == "$POT_VALUE" ]] || die 'DigiPot readback mismatch.'

echo

echo 'CFG1 DigiPot value changed.'
echo 'Power-cycle/reset the serializer before testing the new CFG1 setting.'
