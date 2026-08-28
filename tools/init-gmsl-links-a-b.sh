#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Manual dual-link GMSL2 reverse-I2C bring-up.
#
# I2C control plane only:
#   Link A: IMX708 0x1a -> 0x52; DW9817 0x0c -> 0x5c
#   Link B: IMX708 0x1a -> 0x53; DW9817 0x0c -> 0x5d
#
# It does not load an overlay, a media driver, or configure CSI/video.
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
REMOTE_FOCUS="${REMOTE_FOCUS:-0x0c}"
ALIAS_A="${ALIAS_A:-0x52}"
ALIAS_B="${ALIAS_B:-0x53}"
FOCUS_ALIAS_A="${FOCUS_ALIAS_A:-0x5c}"
FOCUS_ALIAS_B="${FOCUS_ALIAS_B:-0x5d}"

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

read_focus_status() {
  local addr="$1"
  sudo i2ctransfer -f -y "$I2C_BUS" w1@"$addr" 0x05 r1
}

# Update only reference-defined bits, preserving all other receiver state.
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

configure_serializer_and_aliases() {
  local label="$1" sensor_alias="$2" focus_alias="$3"
  local ser_id sensor_id focus_status

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

  # MAX96717 reverse-I2C translators:
  # slot 0: local IMX708 alias -> remote sensor 0x1a
  # slot 1: local DW9817 alias -> remote focus actuator 0x0c
  write_reg "$SER_ADDR" 0042 "$(printf '0x%02x' "$((sensor_alias << 1))")"
  write_reg "$SER_ADDR" 0043 "$(printf '0x%02x' "$((REMOTE_SENSOR << 1))")"
  write_reg "$SER_ADDR" 0044 "$(printf '0x%02x' "$((focus_alias << 1))")"
  write_reg "$SER_ADDR" 0045 "$(printf '0x%02x' "$((REMOTE_FOCUS << 1))")"

  sensor_id="$(read_id "$sensor_alias")" ||
    { echo "ERROR: Link-$label IMX708 alias $sensor_alias is not reachable."; return 1; }
  focus_status="$(read_focus_status "$focus_alias")" ||
    { echo "ERROR: Link-$label DW9817 alias $focus_alias is not reachable."; return 1; }
  echo "IMX708 Link-$label via alias $sensor_alias: $sensor_id"
  echo "DW9817 Link-$label via alias $focus_alias, status: $focus_status"
}

echo "==> Set known Link-A 2K padding value"
sudo i2ctransfer -f -y "$I2C_BUS" w2@"$POT_ADDR" 0x01 "$POT_A_VALUE"

echo "==> Set both MAX96716A links to GMSL2 6 Gbit/s"
update_des_bits 0001 0x03 0x02
update_des_bits 0004 0x03 0x02

echo "==> Configure Link A aliases"
select_links 0x01
configure_serializer_and_aliases A "$ALIAS_A" "$FOCUS_ALIAS_A"

echo "==> Configure Link B aliases"
select_links 0x02
configure_serializer_and_aliases B "$ALIAS_B" "$FOCUS_ALIAS_B"

echo "==> Enable both links (ADI dual-link state)"
select_links 0x03

echo -n "IMX708 Link-A final alias $ALIAS_A: "
read_id "$ALIAS_A"
echo -n "DW9817 Link-A final alias $FOCUS_ALIAS_A: "
read_focus_status "$FOCUS_ALIAS_A"
echo -n "IMX708 Link-B final alias $ALIAS_B: "
read_id "$ALIAS_B"
echo -n "DW9817 Link-B final alias $FOCUS_ALIAS_B: "
read_focus_status "$FOCUS_ALIAS_B"
