#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Enable MAX96716A RLMS3 AdaptEn, preserving all other register bits.
# Usage: sudo bash tools/enable-gmsl-rx-adaptation.sh BUS DES_ADDR A [B]
set -Eeuo pipefail

BUS="${1:?I2C bus required}"
ADDR="${2:?Deserializer address required}"
shift 2
(( $# > 0 )) || { echo 'ERROR: Specify A and/or B.' >&2; exit 1; }
for link in "$@"; do
  case "$link" in
    A|B) ;;
    *) echo "ERROR: Unknown link: $link" >&2; exit 1 ;;
  esac
done

read_reg() {
  i2ctransfer -f -y "$BUS" "w2@$ADDR" "0x${1:0:2}" "0x${1:2:2}" r1
}

for link in "$@"; do
  case "$link" in A) reg=1403 ;; B) reg=1503 ;; esac
  before="$(read_reg "$reg")"
  value="$(printf '0x%02x' "$((before | 0x80))")"
  i2ctransfer -f -y "$BUS" "w3@$ADDR" "0x${reg:0:2}" "0x${reg:2:2}" "$value"
  after="$(read_reg "$reg")"
  printf 'Link %s AdaptEn: %d -> %d [0x%s: %s -> %s]\n' \
    "$link" "$(((before >> 7) & 1))" "$(((after >> 7) & 1))" "$reg" "$before" "$after"
  if (( !(after & 0x80) )); then
    echo "ERROR: Link $link AdaptEn did not remain enabled." >&2
    exit 1
  fi
done
