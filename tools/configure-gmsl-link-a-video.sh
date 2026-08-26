#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Configure only the known Link-A GMSL2 video path:
# IMX708 -> MAX96717 -> MAX96716A pipe 0 -> Port A / DPHY0 -> RP1 CSI1.
#
# Prerequisites:
#   make init-a-b
#   make overlays-a-b
#
# This script deliberately does not configure a Link-B video pipe.
# It preserves the two sensor and focus reverse-I2C aliases set by init-a-b.
set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"

write_reg() {
  local addr="$1" reg="$2" value="$3"
  sudo i2ctransfer -f -y "$I2C_BUS" w3@"$addr" \
    "0x${reg:0:2}" "0x${reg:2:2}" "$value"
}

read_reg() {
  local addr="$1" reg="$2"
  sudo i2ctransfer -f -y "$I2C_BUS" w2@"$addr" \
    "0x${reg:0:2}" "0x${reg:2:2}" r1
}

echo "==> Select Link A for the known video configuration"
# The known Link-A bring-up writes these receiver controls before video setup.
write_reg "$DES_ADDR" 0f00 0x01
write_reg "$DES_ADDR" 0001 0x02
write_reg "$DES_ADDR" 0011 0x0b
write_reg "$DES_ADDR" 0010 0x31

echo "==> Configure MAX96717 Link-A CSI input and tunnel pipe"
# The clock/power/reset and I2C aliases are already configured by init-a-b.
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

echo "==> Configure MAX96716A pipe 0 to Port A / DPHY0"
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

echo "==> Link-A video status"
printf 'MAX96716A pipe enable: '
read_reg "$DES_ADDR" 0160
printf 'MAX96716A pipe select: '
read_reg "$DES_ADDR" 0161
printf 'MAX96716A Port-A lanes: '
read_reg "$DES_ADDR" 044a
printf 'MAX96716A tunnel route: '
read_reg "$DES_ADDR" 0474
printf 'MAX96716A CSI output: '
read_reg "$DES_ADDR" 0313
printf 'MAX96717 stream ID: '
read_reg "$SER_ADDR" 005b
printf 'MAX96717 tunnel mode: '
read_reg "$SER_ADDR" 0383
