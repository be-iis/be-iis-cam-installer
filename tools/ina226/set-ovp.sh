#!/usr/bin/env bash
# Configure INA226 bus-voltage over-limit protection using raw I2C commands.
set -Eeuo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
source "${script_dir}/ina226-common.sh"

usage()
{
    echo 'Usage: sudo beiis-ina226-set-ovp [link-a|link-b|both] [limit-mV] [--auto-release]'
}

configure_ovp()
{
    local label="$1" address="$2" limit_mv="$3" auto_release="$4"
    local limit_counts mask

    limit_counts=$(( (limit_mv * 4 + 2) / 5 ))
    (( limit_counts <= 0x7fff )) ||
        ina226_die "${label}: limit outside INA226 range."

    mask="$(ina226_mask_with_release_mode "$INA226_MASK_BOL" "$auto_release")"
    ina226_check_device "$label" "$address"
    ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" 0
    ina226_write_u16 "$address" "$INA226_REG_ALERT_LIMIT" "$limit_counts"
    ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" "$mask"

    printf '%s: OVP=%d mV, limit=0x%04x, mode=%s\n' \
        "$label" "$limit_mv" "$limit_counts" \
        "$([[ "$auto_release" -eq 1 ]] && printf auto-release || printf latched)"
}

main()
{
    ina226_need_root
    ina226_prepare_bus
    if ! ina226_parse_common_arguments 30000 "$@"; then
        usage
        exit 0
    fi
    ina226_for_selected_links "$INA226_SELECTED_LINKS" configure_ovp \
        "$INA226_REQUESTED_LIMIT" "$INA226_AUTO_RELEASE"
}

main "$@"
