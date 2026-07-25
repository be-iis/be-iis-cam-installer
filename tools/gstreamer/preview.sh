#!/usr/bin/env bash
set -euo pipefail

megapixels=3
framerate=30

usage()
{
	printf 'Usage: beiis-gst-preview [--megapixels 1|3|12|WIDTHxHEIGHT] [--framerate FPS]\n'
}

while (($#)); do
	case "$1" in
		-m|--megapixels) megapixels="$2"; shift 2 ;;
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

command -v gst-launch-1.0 >/dev/null ||
	{ printf 'Error: gst-launch-1.0 is not installed\n' >&2; exit 1; }
gst-inspect-1.0 libcamerasrc >/dev/null 2>&1 ||
	{ printf 'Error: the GStreamer libcamerasrc plugin is not installed\n' >&2; exit 1; }

exec gst-launch-1.0 -e \
	libcamerasrc ! \
	"video/x-raw,width=${width},height=${height},framerate=${framerate}/1" ! \
	queue ! videoconvert ! autovideosink sync=false
