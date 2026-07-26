#!/usr/bin/env bash
# Initialize INA226 protection for both BE-IIS-GMSL-CAM2 PoC links.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${INA226_INIT_ALERT_MODE:-ocp}"
links="${INA226_LINKS:-both}"
auto_release="${INA226_INIT_AUTO_RELEASE:-1}"
args=("$links")
[[ "$auto_release" == 1 ]] && args+=(--auto-release)
case "${mode,,}" in
  ocp) exec "${script_dir}/set-ocp.sh" "${args[@]}" "${INA226_OCP_MA:-400}" ;;
  ovp) exec "${script_dir}/set-ovp.sh" "${args[@]}" "${INA226_OVP_MV:-30000}" ;;
  *) echo "ERROR: select INA226_INIT_ALERT_MODE=ocp or ovp" >&2; exit 1 ;;
esac
