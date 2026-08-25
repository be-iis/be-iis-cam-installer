#!/usr/bin/env bash
# Minimal Link-B bring-up: make only the remote MAX96717 serializer reachable.
# Does not configure the serializer, IMX708, CSI output, overlay, or camera stream.

set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"

(( EUID == 0 )) || { echo "Run with sudo" >&2; exit 1; }
command -v i2ctransfer >/dev/null || { echo "i2ctransfer not found" >&2; exit 1; }

write_reg() {
    i2ctransfer -f -y "$I2C_BUS" "w3@$1" \
        "0x${2:0:2}" "0x${2:2:2}" "$3"
}

read_reg() {
    i2ctransfer -f -y "$I2C_BUS" "w2@$1" \
        "0x${2:0:2}" "0x${2:2:2}" r1
}

echo "==> Selecting GMSL2 Link B for reverse I2C"
write_reg "$DES_ADDR" 0004 0x02
write_reg "$DES_ADDR" 0011 0x0f
write_reg "$DES_ADDR" 0013 0x01
sleep 0.1
write_reg "$DES_ADDR" 0013 0x00

echo -n "MAX96716A Link-B status: "
read_reg "$DES_ADDR" 5009

echo -n "MAX96717 Link-B ID/revision: "
i2ctransfer -f -y "$I2C_BUS" "w2@$SER_ADDR" 0x00 0x0d r2
