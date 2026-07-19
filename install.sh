#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "Error: $1" >&2
    exit 1
}

run_step() {
    name="$1"
    script="$2"

    [ -x "$script" ] || die "Script is missing or not executable: $script"
    printf '\n=== %s ===\n' "$name"
    "$script"
}

for command in wget make gcc patch sudo dtc; do
    command -v "$command" >/dev/null 2>&1 || \
        die "Required command not found: $command"
done

run_step "Sony IMX708 driver" \
    "$SCRIPT_DIR/tools/kernel/imx708_mod_build.sh"
run_step "MAX96717 serializer driver" \
    "$SCRIPT_DIR/tools/kernel/max96717_mod_build.sh"
run_step "MAX96714 deserializer driver" \
    "$SCRIPT_DIR/tools/kernel/max96714_mod_build.sh"
run_step "GMSL2 camera Device Tree overlay" \
    "$SCRIPT_DIR/overlays/build_install_overlay.sh"

printf '\nInstallation completed.\n'
printf 'Add one of the following lines to /boot/firmware/config.txt:\n'
printf '  dtoverlay=max96714-max96717-imx708\n'
printf '  dtoverlay=max96714-max96717-imx708,cam0\n'
printf 'Then reboot the Raspberry Pi.\n'
