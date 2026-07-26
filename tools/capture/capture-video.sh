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
autofocus_enabled=1
autofocus_mode=continuous
autofocus_range=normal
autofocus_speed=normal
autofocus_window=
lens_position=
hdr_mode=off

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
      --no-autofocus
      --autofocus-mode MODE  continuous (default), auto, or manual
      --autofocus-range RANGE
                             normal (default), macro, or full
      --autofocus-speed SPEED
                             normal (default) or fast
      --autofocus-window X,Y,W,H
      --lens-position VALUE  manual focus in dioptres; requires manual mode
      --hdr MODE             off (default), auto, or single-exp
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
		--no-autofocus) autofocus_enabled=0; shift ;;
		--autofocus-mode) autofocus_mode="$2"; shift 2 ;;
		--autofocus-range) autofocus_range="$2"; shift 2 ;;
		--autofocus-speed) autofocus_speed="$2"; shift 2 ;;
		--autofocus-window) autofocus_window="$2"; shift 2 ;;
		--lens-position) lens_position="$2"; shift 2 ;;
		--hdr) hdr_mode="$2"; shift 2 ;;
		--no-hdr) hdr_mode=off; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

resolve_mode "$megapixels"
validate_autofocus_options
validate_hdr_options
check_camera
need_command rpicam-vid
case "$codec" in h264|mjpeg) ;; *) die "unsupported codec: $codec" ;; esac
if [[ -z "$output" ]]; then
	case "$codec" in h264) output=video.h264 ;; mjpeg) output=video.mjpeg ;; esac
fi

args=(
	--camera "$camera" --nopreview
	--mode "${CAPTURE_WIDTH}:${CAPTURE_HEIGHT}:10:P"
	--width "$CAPTURE_WIDTH" --height "$CAPTURE_HEIGHT"
	--framerate "$framerate" --codec "$codec"
	--timeout "$((duration * 1000))" --output "$output"
)
append_autofocus_args args
args+=(--hdr "$hdr_mode")
case "$codec" in h264) args+=(--bitrate "$bitrate") ;; mjpeg) args+=(--quality "$quality") ;; esac

printf 'Recording %sx%s at %s fps to %s\n' \
	"$CAPTURE_WIDTH" "$CAPTURE_HEIGHT" "$framerate" "$output"
rpicam-vid "${args[@]}"
