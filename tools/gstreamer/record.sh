#!/usr/bin/env bash
set -euo pipefail

megapixels=3
framerate=30
duration=10
output=video.mp4

usage()
{
	cat <<'EOF'
Usage: beiis-gst-record [options]
  -m, --megapixels 1|3|12|WIDTHxHEIGHT
  -o, --output FILE.mp4
  -d, --duration SECONDS
      --framerate FPS
EOF
}

while (($#)); do
	case "$1" in
		-m|--megapixels) megapixels="$2"; shift 2 ;;
		-o|--output) output="$2"; shift 2 ;;
		-d|--duration) duration="$2"; shift 2 ;;
		--framerate) framerate="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Error: unknown option: %s\n' "$1" >&2; exit 1 ;;
	esac
done

case "$megapixels" in
	1|1mp|1MP) width=1536; height=864 ;;
	3|3mp|3MP) width=2304; height=1296 ;;
	12|12mp|12MP) width=4608; height=2592 ;;
	[0-9]*x[0-9]*) width="${megapixels%x*}"; height="${megapixels#*x}" ;;
	*) printf 'Error: invalid resolution: %s\n' "$megapixels" >&2; exit 1 ;;
esac

for command in gst-launch-1.0 gst-inspect-1.0 timeout; do
	command -v "$command" >/dev/null ||
		{ printf 'Error: %s is not installed\n' "$command" >&2; exit 1; }
done

gst-inspect-1.0 libcamerasrc >/dev/null 2>&1 ||
	{ printf 'Error: the GStreamer libcamerasrc plugin is not installed\n' >&2; exit 1; }

if gst-inspect-1.0 v4l2h264enc >/dev/null 2>&1; then
	encoder=(v4l2h264enc extra-controls="controls,video_bitrate=12000000")
elif gst-inspect-1.0 x264enc >/dev/null 2>&1; then
	encoder=(x264enc bitrate=12000 speed-preset=veryfast tune=zerolatency)
else
	printf 'Error: neither v4l2h264enc nor x264enc is available\n' >&2
	exit 1
fi

printf 'Recording %sx%s at %s fps for %s seconds to %s\n' \
	"$width" "$height" "$framerate" "$duration" "$output"

timeout --signal=INT "${duration}s" \
	gst-launch-1.0 -e \
	libcamerasrc ! \
	"video/x-raw,width=${width},height=${height},framerate=${framerate}/1" ! \
	queue ! videoconvert ! "${encoder[@]}" ! \
	h264parse ! mp4mux ! filesink "location=${output}"
