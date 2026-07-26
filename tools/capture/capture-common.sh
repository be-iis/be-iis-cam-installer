#!/usr/bin/env bash

die()
{
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

need_command()
{
	command -v "$1" >/dev/null 2>&1 ||
		die "required command not found: $1"
}

resolve_mode()
{
	case "$1" in
		1|1mp|1MP)
			CAPTURE_WIDTH=1536
			CAPTURE_HEIGHT=864
			;;
		3|3mp|3MP)
			CAPTURE_WIDTH=2304
			CAPTURE_HEIGHT=1296
			;;
		12|12mp|12MP)
			CAPTURE_WIDTH=4608
			CAPTURE_HEIGHT=2592
			;;
		[0-9]*x[0-9]*)
			CAPTURE_WIDTH="${1%x*}"
			CAPTURE_HEIGHT="${1#*x}"
			;;
		*)
			die "unknown resolution '$1'; use 1, 3, 12, or WIDTHxHEIGHT"
			;;
	esac
}

check_camera()
{
	local cameras

	need_command rpicam-hello

	cameras="$(rpicam-hello --list-cameras 2>&1 || true)"
	if ! grep -qE '^[0-9]+[[:space:]]*:' <<<"$cameras"; then
		die "no camera found; run: sudo systemctl restart be-iis-camera-init.service"
	fi
}
