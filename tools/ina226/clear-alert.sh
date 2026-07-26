#!/usr/bin/env bash
# Clear a latched INA226 alert by reading the Mask/Enable register.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/ina226-common.sh"
clear_one(){ local label="$1" address="$2"; ina226_check_device "$label" "$address"; printf '%s: alert acknowledged; Mask/Enable=%s\n' "$label" "$(ina226_read_u16 "$address" "$INA226_REG_MASK_ENABLE")"; }
main(){ local selector="${1:-both}"; (( $# <= 1 )) || ina226_die 'Too many arguments.'; ina226_need_root; ina226_prepare_bus; ina226_for_selected_links "$selector" clear_one; }
main "$@"
