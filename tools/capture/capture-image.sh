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
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

resolve_mode "$megapixels"
check_camera
need_command rpicam-still

args=(
	--camera "$camera"
	--nopreview
	--mode "${CAPTURE_WIDTH}:${CAPTURE_HEIGHT}:10:P"
	--width "$CAPTURE_WIDTH"
	--height "$CAPTURE_HEIGHT"
	--timeout "$timeout_ms"
	--output "$output"
)

[[ -z "$shutter" ]] || args+=(--shutter "$shutter")
[[ -z "$gain" ]] || args+=(--gain "$gain")
[[ "$raw" -eq 0 ]] || args+=(--raw)

printf 'Capturing %sx%s to %s\n' \
	"$CAPTURE_WIDTH" "$CAPTURE_HEIGHT" "$output"
rpicam-still "${args[@]}"
