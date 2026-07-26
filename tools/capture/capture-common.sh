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
		1|1mp|1MP) CAPTURE_WIDTH=1536; CAPTURE_HEIGHT=864 ;;
		3|3mp|3MP) CAPTURE_WIDTH=2304; CAPTURE_HEIGHT=1296 ;;
		12|12mp|12MP) CAPTURE_WIDTH=4608; CAPTURE_HEIGHT=2592 ;;
		[0-9]*x[0-9]*)
			CAPTURE_WIDTH="${1%x*}"
			CAPTURE_HEIGHT="${1#*x}"
			;;
		*) die "unknown resolution '$1'; use 1, 3, 12, or WIDTHxHEIGHT" ;;
	esac
}

check_camera()
{
	local cameras
	need_command rpicam-hello
	cameras="$(rpicam-hello --list-cameras 2>&1 || true)"
	grep -qE '^[0-9]+[[:space:]]*:' <<<"$cameras" ||
		die "no camera found; run: sudo systemctl restart be-iis-camera-init.service"
}

validate_autofocus_options()
{
	case "$autofocus_mode" in manual|auto|continuous) ;; *)
		die "invalid autofocus mode '$autofocus_mode'; use manual, auto, or continuous" ;;
	esac
	case "$autofocus_range" in normal|macro|full) ;; *)
		die "invalid autofocus range '$autofocus_range'; use normal, macro, or full" ;;
	esac
	case "$autofocus_speed" in normal|fast) ;; *)
		die "invalid autofocus speed '$autofocus_speed'; use normal or fast" ;;
	esac
	if [[ -n "$lens_position" && "$autofocus_mode" != manual ]]; then
		die "--lens-position requires --autofocus-mode manual"
	fi
}

append_autofocus_args()
{
	local -n destination="$1"

	if [[ "$autofocus_enabled" -eq 0 ]]; then
		destination+=(--autofocus-mode manual)
		return
	fi

	destination+=(
		--autofocus-mode "$autofocus_mode"
		--autofocus-range "$autofocus_range"
		--autofocus-speed "$autofocus_speed"
	)
	[[ -z "$autofocus_window" ]] ||
		destination+=(--autofocus-window "$autofocus_window")
	[[ -z "$lens_position" ]] ||
		destination+=(--lens-position "$lens_position")
}
