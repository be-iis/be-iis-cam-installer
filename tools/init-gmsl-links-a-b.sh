#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Manual dual-link GMSL2 reverse-I2C bring-up.
#
# This script configures only the I2C control plane:
#   Link A: IMX708 0x1a -> upstream alias 0x52
#   Link B: IMX708 0x1a -> upstream alias 0x53
#
# It does not install a driver, create an overlay, configure CSI/video,
# or start a camera application.
#
# Link selection follows Analog Devices max9296a_select_links():
# 0x0f00 = enabled links; 0x0010 = AUTO_LINK | LINK_CFG | RESET_ONESHOT;
# MAX96716A additionally uses the per-link reset bit at 0x0012.
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
POT_ADDR="${POT_ADDR:-0x51}"
POT_A_VALUE="${POT_A_VALUE:-0xae}"
REMOTE_SENSOR="${REMOTE_SENSOR:-0x1a}"
ALIAS_A="${ALIAS_A:-0x52}"
ALIAS_B="${ALIAS_B:-0x53}"

write_reg() {
  local addr="$1" reg="$2" value="$3"
  sudo i2ctransfer -f -y "$I2C_BUS" w3@"$addr" \
    "0x${reg:0:2}" "0x${reg:2:2}" "$value"
}

read_byte() {
  local addr="$1" reg="$2"
  sudo i2ctransfer -f -y "$I2C_BUS" w2@"$addr" \
    "0x${reg:0:2}" "0x${reg:2:2}" r1
}

read_id() {
  local addr="$1"
  sudo i2ctransfer -f -y "$I2C_BUS" w2@"$addr" 0x00 0x16 r2
}

# Update only the reference-defined bits, preserving all other receiver state.
update_des_bits() {
  local reg="$1" mask="$2" value="$3"
  local current_hex current next

  current_hex="$(read_byte "$DES_ADDR" "$reg")"
  current=$((current_hex))
  next=$(((current & ~mask) | (value & mask)))
  write_reg "$DES_ADDR" "$reg" "$(printf '0x%02x' "$next")"
}

# ADI select_links sequence. mask: 1=Link A, 2=Link B, 3=both.
select_links() {
  local mask="$1"

  update_des_bits 0f00 0x03 "$mask"
  update_des_bits 0010 0x33 "$((0x30 | mask))"
  # MAX96716A has a per-link one-shot reset (ADI max96716a_info).
  update_des_bits 0012 0x20 0x20
  sleep 0.2
}

configure_serializer_and_alias() {
  local label="$1" alias="$2"
  local ser_id sensor_id

  ser_id="$(sudo i2ctransfer -f -y "$I2C_BUS" w2@"$SER_ADDR" 0x00 0x0d r2)" ||
    { echo "ERROR: Link-$label serializer is not reachable."; return 1; }
  echo "MAX96717 Link-$label ID/revision: $ser_id"

  # Known working MAX96717 camera clock/power/reset and two-lane CSI input setup.
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

  # MAX96717 reverse-I2C translation: local alias -> remote IMX708 address.
  write_reg "$SER_ADDR" 0042 "$(printf '0x%02x' "$((alias << 1))")"
  write_reg "$SER_ADDR" 0043 "$(printf '0x%02x' "$((REMOTE_SENSOR << 1))")"
  write_reg "$SER_ADDR" 0044 0x00
  write_reg "$SER_ADDR" 0045 0x00

  sensor_id="$(read_id "$alias")" ||
    { echo "ERROR: Link-$label IMX708 alias $alias is not reachable."; return 1; }
  echo "IMX708 Link-$label via alias $alias: $sensor_id"
}

echo "==> Set known Link-A 2K padding value"
sudo i2ctransfer -f -y "$I2C_BUS" w2@"$POT_ADDR" 0x01 "$POT_A_VALUE"

echo "==> Set both MAX96716A links to GMSL2 6 Gbit/s"
update_des_bits 0001 0x03 0x02
update_des_bits 0004 0x03 0x02

echo "==> Configure Link A and alias $ALIAS_A"
select_links 0x01
configure_serializer_and_alias A "$ALIAS_A"

echo "==> Configure Link B and alias $ALIAS_B"
select_links 0x02
configure_serializer_and_alias B "$ALIAS_B"

echo "==> Enable both links (ADI dual-link state)"
select_links 0x03

echo -n "IMX708 Link-A final alias $ALIAS_A: "
read_id "$ALIAS_A"
echo -n "IMX708 Link-B final alias $ALIAS_B: "
read_id "$ALIAS_B"
