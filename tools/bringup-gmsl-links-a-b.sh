#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Verified dual-camera video sequence for the BE-IIS 2CAM HAT.
#
# Prerequisite: make cameras-a-b
#
# Topology:
#   Link A: IMX708@0x52 -> MAX96717 -> MAX96716A Pipe Y -> Port A -> Pi CSI1
#   Link B: IMX708@0x53 -> MAX96717 -> MAX96716A Pipe Z -> Port B -> Pi CSI0
#
# The MAX96716A stream selectors are essential:
#   0x0161 = 0x20  Pipe Y <- Link-A stream 0; Pipe Z <- Link-B stream 0
#   0x0160 = 0x03  enable both pipes
#
# Both IMX708 cameras emit CSI stream 0. Selecting stream 2 (the former 0x32
# state) leaves the Pi with no packets although the sensor and serializer run.
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
SENSOR_A="${SENSOR_A:-0x52}"
SENSOR_B="${SENSOR_B:-0x53}"
FOCUS_A="${FOCUS_A:-0x5c}"
FOCUS_B="${FOCUS_B:-0x5d}"

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
  local address="$1"
  i2ctransfer -f -y "$I2C_BUS" "w2@${address}" 0x00 0x16 r2
}

read_serializer_id() {
  i2ctransfer -f -y "$I2C_BUS" "w2@${SER_ADDR}" 0x00 0x0d r2
}

select_link() {
  local link="$1" enable reset
  case "$link" in
    A) enable=0x01; reset=0x31 ;;
    B) enable=0x02; reset=0x32 ;;
    *) die "unknown link: $link" ;;
  esac

  # ADI-derived selection: temporarily select one physical reverse-I2C path.
  write_reg "$DES_ADDR" 0f00 "$enable"
  write_reg "$DES_ADDR" 0010 "$reset"
  write_reg "$DES_ADDR" 0012 0x20
  sleep 0.2
}

configure_serializer_csi() {
  local link="$1" sensor="$2" focus="$3" focus_alias
  if [[ "$link" == A ]]; then focus_alias=0xb8; else focus_alias=0xba; fi

  echo "==> Configure MAX96717 Link-$link CSI input, tunnel and focus alias"
  [[ "$(read_serializer_id)" == '0xbf 0x06' ]] ||
    die "Link-$link serializer is not reachable."

  # Second MAX96717 translator: local focus alias -> remote DW9807 0x0c.
  write_reg "$SER_ADDR" 0044 "$focus_alias"
  write_reg "$SER_ADDR" 0045 0x18
  printf 'DW9807 Link-%s status: ' "$link"
  i2ctransfer -f -y "$I2C_BUS" "w1@${focus}" 0x05 r1

  # Two data lanes, RAW stream 0. The final 0x43 enables the tunnel pipe.
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

  printf 'IMX708 Link-%s: ' "$link"
  read_id "$sensor"
}

configure_deser_port_a() {
  echo '==> Configure MAX96716A Port A / DPHY0-1 for Link A'
  write_reg "$DES_ADDR" 0313 0x00
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
}

configure_deser_port_b() {
  echo '==> Configure MAX96716A Port B / DPHY2-3 for Link B'
  write_reg "$DES_ADDR" 0313 0x00
  write_reg "$DES_ADDR" 0308 0x01
  write_reg "$DES_ADDR" 031d 0x2f
  write_reg "$DES_ADDR" 0323 0x29
  write_reg "$DES_ADDR" 0326 0x29
  write_reg "$DES_ADDR" 0330 0x04
  write_reg "$DES_ADDR" 0332 0xf4
  write_reg "$DES_ADDR" 0333 0x4e
  write_reg "$DES_ADDR" 0334 0xe4
  write_reg "$DES_ADDR" 0335 0x00
  write_reg "$DES_ADDR" 0336 0x00
  write_reg "$DES_ADDR" 0480 0x01
  write_reg "$DES_ADDR" 0483 0x01
  write_reg "$DES_ADDR" 0484 0x01
  write_reg "$DES_ADDR" 0485 0x71
  write_reg "$DES_ADDR" 0486 0x19
  write_reg "$DES_ADDR" 0487 0x1c
  write_reg "$DES_ADDR" 0489 0x01
  write_reg "$DES_ADDR" 048a 0x50
  write_reg "$DES_ADDR" 04b4 0x0f
  write_reg "$DES_ADDR" 1e00 0xf4
  sleep 0.02
  write_reg "$DES_ADDR" 1e00 0xf5
}

main() {
  (( EUID == 0 )) || die 'Run with sudo.'
  command -v i2ctransfer >/dev/null || die 'i2ctransfer not found.'
  [[ -e "/dev/i2c-${I2C_BUS}" ]] || die "/dev/i2c-${I2C_BUS} does not exist."

  select_link A
  configure_serializer_csi A "$SENSOR_A" "$FOCUS_A"
  configure_deser_port_a

  select_link B
  configure_serializer_csi B "$SENSOR_B" "$FOCUS_B"
  configure_deser_port_b

  echo '==> Route Pipe Y to Link-A stream 0 and Pipe Z to Link-B stream 0'
  write_reg "$DES_ADDR" 0161 0x20
  write_reg "$DES_ADDR" 0160 0x03
  write_reg "$DES_ADDR" 0313 0x02

  # Leave both reverse-I2C links enabled for the two Linux sensor drivers.
  write_reg "$DES_ADDR" 0f00 0x03
  write_reg "$DES_ADDR" 0010 0x33
  write_reg "$DES_ADDR" 0012 0x20

  echo '==> Dual video configuration complete'
  printf 'MAX96716A VIDEO_PIPE_EN: '
  read_reg "$DES_ADDR" 0160
  printf 'MAX96716A VIDEO_PIPE_SEL: '
  read_reg "$DES_ADDR" 0161
}

main "$@"
