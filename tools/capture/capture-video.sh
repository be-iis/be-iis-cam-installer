#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common=/usr/libexec/be-iis-camera/capture-common.sh
[[ -r "$common" ]] || common="$script_dir/capture-common.sh"
# shellcheck source=capture-common.sh
source "$common"

megapixels=3
output=
duration=10
framerate=30
bitrate=12000000
quality=85
codec=mjpeg
camera=0

usage()
{
	cat <<'EOF'
Usage: beiis-capture-video [options]

  -m, --megapixels 1|3|12|WIDTHxHEIGHT
  -o, --output FILE
  -d, --duration SECONDS
      --framerate FPS
      --bitrate BITS_PER_SECOND
      --quality 1..100
      --codec h264|mjpeg
      --camera INDEX
  -h, --help
EOF
}

while (($#)); do
	case "$1" in
		-m|--megapixels) megapixels="$2"; shift 2 ;;
		-o|--output) output="$2"; shift 2 ;;
		-d|--duration) duration="$2"; shift 2 ;;
		--framerate) framerate="$2"; shift 2 ;;
		--bitrate) bitrate="$2"; shift 2 ;;
		--quality) quality="$2"; shift 2 ;;
		--codec) codec="$2"; shift 2 ;;
		--camera) camera="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

resolve_mode "$megapixels"
check_camera
need_command rpicam-vid

case "$codec" in
	h264|mjpeg) ;;
	*) die "unsupported codec: $codec" ;;
esac

if [[ -z "$output" ]]; then
	case "$codec" in
		h264) output=video.h264 ;;
		mjpeg) output=video.mjpeg ;;
	esac
fi

printf 'Recording %sx%s at %s fps to %s\n' \
	"$CAPTURE_WIDTH" "$CAPTURE_HEIGHT" "$framerate" "$output"

args=(
	--camera "$camera"
	--nopreview
	--mode "${CAPTURE_WIDTH}:${CAPTURE_HEIGHT}:10:P"
	--width "$CAPTURE_WIDTH"
	--height "$CAPTURE_HEIGHT"
	--framerate "$framerate"
	--codec "$codec"
	--timeout "$((duration * 1000))"
	--output "$output"
)

case "$codec" in
	h264) args+=(--bitrate "$bitrate") ;;
	mjpeg) args+=(--quality "$quality") ;;
esac

rpicam-vid "${args[@]}"
