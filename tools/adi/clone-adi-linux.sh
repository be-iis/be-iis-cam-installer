#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="https://github.com/analogdevicesinc/linux.git"
readonly BRANCH="gmsl/rpi-6.13.y"

usage() {
	cat <<'EOF'
Clone the official Analog Devices GMSL Raspberry Pi kernel source.

Usage:
  clone-adi-linux.sh --destination <path>

Options:
  --destination  New directory for the ADI Linux source tree
  -h, --help     Display this help

The script only clones the source. Follow README-GMSL.md in the cloned tree
to build and install the complete kernel/image.
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

destination=""

while (($#)); do
	case "$1" in
		--destination)
			(($# >= 2)) || die "--destination requires a value"
			destination="$2"
			shift 2
			;;
		--destination=*)
			destination="${1#*=}"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

[[ -n "$destination" ]] || die "missing --destination"
command -v git >/dev/null 2>&1 || die "required command not found: git"
[[ ! -e "$destination" ]] ||
	die "destination already exists: $destination"

printf 'Cloning %s (%s) into %s\n' "$REPOSITORY" "$BRANCH" "$destination"
git clone --depth 1 --branch "$BRANCH" "$REPOSITORY" "$destination"

printf '\nClone completed.\n'
printf 'Read the kernel build instructions in:\n'
printf '  %s/README-GMSL.md\n' "$destination"
