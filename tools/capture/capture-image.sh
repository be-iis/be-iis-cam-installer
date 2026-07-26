#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common=/usr/libexec/be-iis-camera/capture-common.sh
[[ -r "$common" ]] || common="$script_dir/capture-common.sh"
# shellcheck source=capture-common.sh
source "$common"

megapixels=3
output=image.jpg
timeout_ms=3000
shutter=
gain=
raw=0
camera=0
autofocus_enabled=1
autofocus_mode=auto
autofocus_range=normal
autofocus_speed=normal
autofocus_window=
lens_position=

usage()
{
	cat <<'EOF'
Usage: beiis-capture-image [options]

  -m, --megapixels 1|3|12|WIDTHxHEIGHT
  -o, --output FILE.jpg
      --timeout MILLISECONDS
      --shutter MICROSECONDS
      --gain VALUE
      --camera INDEX
      --raw                  also write a DNG beside the JPEG
      --no-autofocus         disable autofocus
      --autofocus-mode MODE  auto (default), continuous, or manual
      --autofocus-range RANGE
                             normal (default), macro, or full
      --autofocus-speed SPEED
                             normal (default) or fast
      --autofocus-window X,Y,W,H
      --lens-position VALUE  manual focus in dioptres; requires manual mode
  -h, --help
EOF
}

while (($#)); do
	case "$1" in
		-m|--megapixels) megapixels="$2"; shift 2 ;;
		-o|--output) output="$2"; shift 2 ;;
		--timeout) timeout_ms="$2"; shift 2 ;;
		--shutter) shutter="$2"; shift 2 ;;
		--gain) gain="$2"; shift 2 ;;
		--camera) camera="$2"; shift 2 ;;
		--raw) raw=1; shift ;;
		--no-autofocus) autofocus_enabled=0; shift ;;
		--autofocus-mode) autofocus_mode="$2"; shift 2 ;;
		--autofocus-range) autofocus_range="$2"; shift 2 ;;
		--autofocus-speed) autofocus_speed="$2"; shift 2 ;;
		--autofocus-window) autofocus_window="$2"; shift 2 ;;
		--lens-position) lens_position="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

resolve_mode "$megapixels"
validate_autofocus_options
check_camera
need_command rpicam-still

args=(
	--camera "$camera" --nopreview
	--mode "${CAPTURE_WIDTH}:${CAPTURE_HEIGHT}:10:P"
	--width "$CAPTURE_WIDTH" --height "$CAPTURE_HEIGHT"
	--timeout "$timeout_ms" --output "$output"
)
append_autofocus_args args
[[ "$autofocus_enabled" -eq 0 || "$autofocus_mode" != auto ]] ||
	args+=(--autofocus-on-capture)
[[ -z "$shutter" ]] || args+=(--shutter "$shutter")
[[ -z "$gain" ]] || args+=(--gain "$gain")
[[ "$raw" -eq 0 ]] || args+=(--raw)

printf 'Capturing %sx%s to %s\n' "$CAPTURE_WIDTH" "$CAPTURE_HEIGHT" "$output"
rpicam-still "${args[@]}"
