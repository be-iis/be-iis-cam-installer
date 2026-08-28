#!/usr/bin/env bash
# Build and install the BE-IIS patched IMX708 kernel module.
# This script has no I2C, overlay or systemd side effects.

set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec make -C "$repo_dir/drivers/imx708" prepare fetch patch build install
