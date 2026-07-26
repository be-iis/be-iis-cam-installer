#!/usr/bin/env bash
# Configure INA226 shunt-voltage over-limit protection using raw I2C commands.
# Default behavior is latched. Add --auto-release for transparent operation.
set -Eeuo pipefail

script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
source "${script_dir}/ina226-common.sh"

usage()
{
    cat <<'USAGE'
Usage: sudo beiis-ina226-set-ocp [link-a|link-b|both] [limit-mA] [--auto-release]
Defaults: both, 400 mA, 10 mOhm, latched.
USAGE
}

configure_ocp()
{
    local label="$1"
    local address="$2"
    local limit_ma="$3"
    local auto_release="$4"
    local shunt_uv
    local limit_counts
    local mask

    shunt_uv=$(( limit_ma * INA226_SHUNT_MOHM ))
    limit_counts=$(( (shunt_uv * 2 + 2) / 5 ))

    (( limit_counts > 0 && limit_counts <= 0x7fff )) ||
        ina226_die "${label}: limit outside INA226 range."

    mask="$(ina226_mask_with_release_mode "$INA226_MASK_SOL" "$auto_release")"

    ina226_check_device "$label" "$address"
    ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" 0
    ina226_write_u16 "$address" "$INA226_REG_ALERT_LIMIT" "$limit_counts"
    ina226_write_u16 "$address" "$INA226_REG_MASK_ENABLE" "$mask"

    printf '%s: OCP=%d mA, shunt=%d mOhm, limit=0x%04x, mode=%s\n' \
        "$label" "$limit_ma" "$INA226_SHUNT_MOHM" "$limit_counts" \
        "$([[ "$auto_release" -eq 1 ]] && printf auto-release || printf latched)"
}

main()
{
    ina226_need_root
    ina226_prepare_bus

    if ! ina226_parse_common_arguments 400 "$@"; then
        usage
        exit 0
    fi

    ina226_for_selected_links \
        "$INA226_SELECTED_LINKS" \
        configure_ocp \
        "$INA226_REQUESTED_LIMIT" \
        "$INA226_AUTO_RELEASE"
}

main "$@"
