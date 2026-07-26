#!/usr/bin/env bash
# Common raw-I2C helpers for the two INA226 devices on BE-IIS-GMSL-CAM2.
# No INA226 kernel driver is used; all register accesses use i2ctransfer.

# INA226 addresses derived from the hardware address straps:
#   Link A: A1=VS,  A0=VS  -> 0x45
#   Link B: A1=GND, A0=VS  -> 0x41
INA226_I2C_BUS="${INA226_I2C_BUS:-${I2C_BUS:-11}}"
INA226_LINK_A_ADDR="${INA226_LINK_A_ADDR:-0x45}"
INA226_LINK_B_ADDR="${INA226_LINK_B_ADDR:-0x41}"

# Fitted board shunt value. With 10 mOhm, a 400 mA limit equals 4 mV
# shunt voltage and 1600 INA226 shunt-voltage counts (0x0640).
INA226_SHUNT_MOHM="${INA226_SHUNT_MOHM:-10}"

INA226_REG_SHUNT_VOLTAGE=0x01
INA226_REG_BUS_VOLTAGE=0x02
INA226_REG_MASK_ENABLE=0x06
INA226_REG_ALERT_LIMIT=0x07
INA226_REG_MANUFACTURER_ID=0xfe
INA226_MANUFACTURER_ID="0x54 0x49"

# Mask/Enable register function bits.
INA226_MASK_SOL=0x8000  # Shunt-voltage over-limit (used for OCP).
INA226_MASK_BOL=0x2000  # Bus-voltage over-limit (used for OVP).
INA226_MASK_LEN=0x0001  # Latch enable; clear for transparent/auto-release.

ina226_die()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ina226_need_root()
{
    (( EUID == 0 )) || ina226_die "Run this command with sudo."
}

ina226_prepare_bus()
{
    command -v i2ctransfer >/dev/null 2>&1 ||
        ina226_die "i2ctransfer is missing. Install the i2c-tools package."

    # i2c-dev is only the generic userspace I2C interface. No INA226-specific
    # kernel driver is loaded or required.
    if command -v modprobe >/dev/null 2>&1; then
        modprobe i2c-dev
    fi

    [[ -e "/dev/i2c-${INA226_I2C_BUS}" ]] ||
        ina226_die "/dev/i2c-${INA226_I2C_BUS} does not exist."
}

ina226_write_u16()
{
    local address="$1"
    local reg="$2"
    local value="$3"
    local msb=$(( (value >> 8) & 0xff ))
    local lsb=$(( value & 0xff ))

    i2ctransfer -f -y "$INA226_I2C_BUS" \
        "w3@${address}" \
        "$(printf '0x%02x' "$((reg))")" \
        "$(printf '0x%02x' "$msb")" \
        "$(printf '0x%02x' "$lsb")"
}

ina226_read_u16()
{
    local address="$1"
    local reg="$2"

    i2ctransfer -f -y "$INA226_I2C_BUS" \
        "w1@${address}" \
        "$(printf '0x%02x' "$((reg))")" \
        r2
}

ina226_raw_bytes_to_u16()
{
    local raw="$1"
    local msb
    local lsb
    local extra

    read -r msb lsb extra <<<"$raw"
    [[ -n "${msb:-}" && -n "${lsb:-}" && -z "${extra:-}" ]] ||
        ina226_die "Unexpected two-byte register response: '${raw}'."

    printf '%u\n' "$(( (msb << 8) | lsb ))"
}

ina226_read_u16_value()
{
    local address="$1"
    local reg="$2"
    local raw

    raw="$(ina226_read_u16 "$address" "$reg")"
    ina226_raw_bytes_to_u16 "$raw"
}

ina226_u16_to_s16()
{
    local value="$1"

    if (( value & 0x8000 )); then
        printf '%d\n' "$(( value - 0x10000 ))"
    else
        printf '%d\n' "$value"
    fi
}

ina226_divide_round_signed()
{
    local numerator="$1"
    local denominator="$2"

    (( denominator > 0 )) || ina226_die "Division denominator must be positive."
    if (( numerator < 0 )); then
        printf '%d\n' "$(( -((-numerator + denominator / 2) / denominator) ))"
    else
        printf '%d\n' "$(( (numerator + denominator / 2) / denominator ))"
    fi
}

ina226_format_fixed()
{
    local value="$1"
    local decimals="$2"
    local scale=1
    local sign=""
    local whole
    local fraction
    local i

    for (( i = 0; i < decimals; i++ )); do
        scale=$(( scale * 10 ))
    done

    if (( value < 0 )); then
        sign="-"
        value=$(( -value ))
    fi

    whole=$(( value / scale ))
    fraction=$(( value % scale ))
    printf '%s%d.%0*d' "$sign" "$whole" "$decimals" "$fraction"
}

ina226_check_device()
{
    local label="$1"
    local address="$2"
    local manufacturer_id

    manufacturer_id="$(ina226_read_u16 "$address" "$INA226_REG_MANUFACTURER_ID" 2>/dev/null || true)"
    [[ "$manufacturer_id" == "$INA226_MANUFACTURER_ID" ]] ||
        ina226_die "${label}: INA226 not found at ${address} on I2C bus ${INA226_I2C_BUS} (manufacturer ID: ${manufacturer_id:-unavailable})."
}

ina226_for_selected_links()
{
    local selector="$1"
    local callback="$2"
    shift 2

    case "${selector,,}" in
        a|link-a|link_a)
            "$callback" "Link A" "$INA226_LINK_A_ADDR" "$@"
            ;;
        b|link-b|link_b)
            "$callback" "Link B" "$INA226_LINK_B_ADDR" "$@"
            ;;
        both|all)
            "$callback" "Link A" "$INA226_LINK_A_ADDR" "$@"
            "$callback" "Link B" "$INA226_LINK_B_ADDR" "$@"
            ;;
        *)
            ina226_die "Unknown link '${selector}'. Use link-a, link-b or both."
            ;;
    esac
}

ina226_parse_common_arguments()
{
    local default_limit="$1"
    shift

    INA226_SELECTED_LINKS="both"
    INA226_REQUESTED_LIMIT="$default_limit"
    INA226_AUTO_RELEASE=0

    while (( $# )); do
        case "$1" in
            a|A|b|B|link-a|link_a|link-b|link_b|both|all)
                INA226_SELECTED_LINKS="$1"
                ;;
            --auto-release)
                INA226_AUTO_RELEASE=1
                ;;
            --latch)
                INA226_AUTO_RELEASE=0
                ;;
            -h|--help|help)
                return 2
                ;;
            ''|*[!0-9]*)
                ina226_die "Invalid argument '$1'. Thresholds must be positive integers."
                ;;
            *)
                INA226_REQUESTED_LIMIT="$1"
                ;;
        esac
        shift
    done

    (( INA226_REQUESTED_LIMIT > 0 )) ||
        ina226_die "Threshold must be greater than zero."
}

ina226_mask_with_release_mode()
{
    local function_mask="$1"
    local auto_release="$2"

    if (( auto_release )); then
        printf '%u\n' "$function_mask"
    else
        printf '%u\n' "$(( function_mask | INA226_MASK_LEN ))"
    fi
}
