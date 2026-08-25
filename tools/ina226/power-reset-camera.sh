#!/usr/bin/env bash
# Assert the native INA226 ALERT/reset path for a camera, then release it.
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/ina226-common.sh"
link="${1:-}"
case "${link,,}" in
  link-a|a) label="Link A"; address="$INA226_LINK_A_ADDR" ;;
  link-b|b) label="Link B"; address="$INA226_LINK_B_ADDR" ;;
  *) ina226_die "Usage: $0 <link-a|link-b>" ;;
esac
hold_s="${CAMERA_POWER_RESET_HOLD_S:-3}"
[[ "$hold_s" =~ ^[0-9]+$ ]] && (( hold_s > 0 )) || ina226_die "CAMERA_POWER_RESET_HOLD_S must be a positive integer."
ina226_need_root; ina226_prepare_bus; ina226_check_device "$label" "$address"
threshold_counts=800 # 1.0 V / 1.25 mV per INA226 bus-voltage LSB
ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" 0
ina226_write_u16 "$address" "$INA226_REG_ALERT_LIMIT" "$threshold_counts"
ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" "$((INA226_MASK_BOL | INA226_MASK_LEN))"
printf '%s: ALERT asserted at 1000 mV; holding camera reset for %ss\n' "$label" "$hold_s"
sleep "$hold_s"
ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" 0
printf '%s: ALERT masked; camera reset released\n' "$label"
