#!/usr/bin/env bash
# Dump bus voltage and calculated current using raw INA226 register reads.
set -Eeuo pipefail

# Resolve the real script location. This is required because the public
# command in /usr/local/bin is a symlink into /usr/libexec/be-iis-camera.
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
source "${script_dir}/ina226-common.sh"

dump_one()
{
    local label="$1"
    local address="$2"
    local bus_counts
    local shunt_u16
    local shunt_counts
    local bus_mv100
    local shunt_mv10000
    local current_ma100

    ina226_check_device "$label" "$address"

    bus_counts="$(ina226_read_u16_value "$address" "$INA226_REG_BUS_VOLTAGE")"
    shunt_u16="$(ina226_read_u16_value "$address" "$INA226_REG_SHUNT_VOLTAGE")"
    shunt_counts="$(ina226_u16_to_s16 "$shunt_u16")"

    # Bus voltage LSB: 1.25 mV. Store hundredths of a millivolt.
    bus_mv100=$(( bus_counts * 125 ))

    # Shunt voltage LSB: 2.5 uV. Store ten-thousandths of a millivolt.
    shunt_mv10000=$(( shunt_counts * 25 ))

    # I[mA] = Vshunt[uV] / Rshunt[mOhm]. Store hundredths of a mA.
    current_ma100="$(
        ina226_divide_round_signed \
            "$(( shunt_counts * 250 ))" \
            "$INA226_SHUNT_MOHM"
    )"

    printf '%s %s: voltage=%s mV, current=%s mA, shunt=%s mV\n' \
        "$(date --iso-8601=seconds)" \
        "$label" \
        "$(ina226_format_fixed "$bus_mv100" 2)" \
        "$(ina226_format_fixed "$current_ma100" 2)" \
        "$(ina226_format_fixed "$shunt_mv10000" 4)"
}

main()
{
    local selector="${1:-both}"

    (( $# <= 1 )) || ina226_die "Too many arguments."
    ina226_need_root
    ina226_prepare_bus
    ina226_for_selected_links "$selector" dump_one
}

main "$@"
