#!/usr/bin/env bash
#
# Bring up:
#   IMX708 -> MAX96717 -> GMSL2 Link A (6 Gbit/s)
#          -> MAX96716A Port A / DPHY0 -> Raspberry Pi 5 CAM/DISP1
#
# This reproduces the known working diagnostic state from 2026-07-25:
# RP1-CFE receives complete 2304x1296 RAW10 buffers. The captured image still
# has incomplete/incorrect CSI framing and is therefore intended for bring-up
# and diagnostics, not production use.
#
# Usage:
#   sudo ./init-imx708-gmsl-port-a.sh init
#   sudo ./init-imx708-gmsl-port-a.sh capture [/tmp/imx708-port-a.raw]
#   sudo ./init-imx708-gmsl-port-a.sh status
#   sudo ./init-imx708-gmsl-port-a.sh all [/tmp/imx708-port-a.raw]
#
# Environment overrides:
#   I2C_BUS=11 DES_ADDR=0x28 SER_ADDR=0x40 POT_ADDR=0x51 POT_B=0xba
#   SENSOR_ADDR=0x52 WIDTH=2304 HEIGHT=1296 EXPOSURE=1000 GAIN=500

set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
POT_ADDR="${POT_ADDR:-0x51}"
POT_B="${POT_B:-0xba}"
SENSOR_ADDR="${SENSOR_ADDR:-0x52}"
OVERLAY_NAME="${OVERLAY_NAME:-imx708-gmsl-link-a}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CAMERA_POWER_RESET="${CAMERA_POWER_RESET:-1}"
CAMERA_POWER_RESET_SCRIPT="${CAMERA_POWER_RESET_SCRIPT:-${SCRIPT_DIR}/tools/ina226/power-reset-link-a.sh}"

WIDTH="${WIDTH:-2304}"
HEIGHT="${HEIGHT:-1296}"
EXPOSURE="${EXPOSURE:-1000}"
GAIN="${GAIN:-500}"

MEDIA_DEV=""
VIDEO_NODE=""
SENSOR_NODE=""

log()
{
	printf '\n==> %s\n' "$*"
}

die()
{
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd()
{
	command -v "$1" >/dev/null 2>&1 ||
		die "Required command not found: $1"
}

write_reg()
{
	local address="$1"
	local reg="$2"
	local value="$3"

	i2ctransfer -f -y "$I2C_BUS" \
		"w3@${address}" \
		"0x${reg:0:2}" \
		"0x${reg:2:2}" \
		"$value"
}

read_reg()
{
	local address="$1"
	local reg="$2"

	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${address}" \
		"0x${reg:0:2}" \
		"0x${reg:2:2}" \
		r1
}

read_id()
{
	local address="$1"

	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${address}" 0x00 0x0d r2
}

check_root()
{
	if (( EUID != 0 )); then
		die "Run this script with sudo."
	fi
}

check_tools()
{
	need_cmd i2ctransfer
	need_cmd media-ctl
	need_cmd v4l2-ctl
	need_cmd dtoverlay
	need_cmd modprobe
}

find_media_graph()
{
	local media
	local graph

	MEDIA_DEV=""
	VIDEO_NODE=""
	SENSOR_NODE=""

	for media in /dev/media*; do
		[[ -e "$media" ]] || continue
		graph="$(media-ctl -d "$media" -p 2>/dev/null || true)"

		if grep -q 'driver[[:space:]]*rp1-cfe' <<<"$graph" &&
		   grep -q 'entity .*imx708' <<<"$graph"; then
			MEDIA_DEV="$media"
			break
		fi
	done

	[[ -n "$MEDIA_DEV" ]] ||
		die "Could not find the RP1-CFE media graph containing IMX708."

	for node in /sys/class/video4linux/v4l-subdev*; do
		[[ -e "$node/name" ]] || continue
		if [[ "$(tr -d '\0' <"$node/name")" == "imx708" ]]; then
			SENSOR_NODE="/dev/$(basename "$node")"
			break
		fi
	done

	graph="$(media-ctl -d "$MEDIA_DEV" -p)"
	VIDEO_NODE="$(
		awk '
			/entity .*rp1-cfe-csi2-ch0/ { found=1; next }
			found && /device node name/ { print $NF; exit }
		' <<<"$graph"
	)"

	[[ -n "$VIDEO_NODE" && -e "$VIDEO_NODE" ]] ||
		die "Could not find the rp1-cfe-csi2-ch0 video node."
	[[ -n "$SENSOR_NODE" && -e "$SENSOR_NODE" ]] ||
		die "Could not find the IMX708 V4L2 subdevice."
}

silence_link_b_video()
{
	local serializer_id

	log "Disabling Link-B video pipe before Link-A bring-up"

	# Select Link B for reverse I2C without configuring its CSI path.
	write_reg "$DES_ADDR" 0004 0x02
	write_reg "$DES_ADDR" 0011 0x0f
	write_reg "$DES_ADDR" 0013 0x01
	sleep 0.1
	write_reg "$DES_ADDR" 0013 0x00

	serializer_id="$(read_id "$SER_ADDR" 2>/dev/null || true)"
	if [[ "$serializer_id" == "0xbf 0x06" ]]; then
		# Keep Link B quiet until it is explicitly routed to its own CSI output.
		write_reg "$SER_ADDR" 0002 0x03
		printf 'MAX96717 Link-B ID/revision: %s (video pipe disabled)\n' "$serializer_id"
	else
		printf 'MAX96717 Link-B: unavailable; continuing with Link A only\n'
	fi
}

configure_link()
{
	local status
	local serializer_id
	local attempt

	log "Loading I2C support"
	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] ||
		die "/dev/i2c-${I2C_BUS} does not exist."

	log "Configuring Link-A 2K padding value: ${POT_B}"
	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${POT_ADDR}" 0x01 "$POT_B"

	log "Configuring MAX96716A Link A for GMSL2 6 Gbit/s over coax"
	write_reg "$DES_ADDR" 0001 0x02
	write_reg "$DES_ADDR" 0011 0x0b
	write_reg "$DES_ADDR" 0010 0x31

	serializer_id=""
	for attempt in {1..30}; do
		sleep 0.1
		status="$(read_reg "$DES_ADDR" 0013 2>/dev/null || true)"
		serializer_id="$(read_id "$SER_ADDR" 2>/dev/null || true)"

		if [[ "$serializer_id" == "0xbf 0x06" ]]; then
			break
		fi
	done

	printf 'MAX96716A link status: %s\n' "${status:-unavailable}"
	printf 'MAX96717 ID/revision:   %s\n' "${serializer_id:-unavailable}"

	[[ "$serializer_id" == "0xbf 0x06" ]] ||
		die "MAX96717 did not become reachable. Check coax, power and DigiPot."
}

configure_serializer()
{
	log "Configuring MAX96717 clock, camera power and reset"

	# Keep the video pipe disabled while configuring it.
	write_reg "$SER_ADDR" 0002 0x03

	# IMX708 reference clock on serializer MFP4 / RCLK setup.
	write_reg "$SER_ADDR" 056f 0x0e
	write_reg "$SER_ADDR" 0003 0x07
	write_reg "$SER_ADDR" 03f0 0x5a
	write_reg "$SER_ADDR" 03f0 0x59
	write_reg "$SER_ADDR" 0006 0xb0

	# I2C translation used by the known driver configuration.
	write_reg "$SER_ADDR" 0042 0xa4
	write_reg "$SER_ADDR" 0043 0x34
	write_reg "$SER_ADDR" 0044 0x00
	write_reg "$SER_ADDR" 0045 0x00

	# Camera power enable and XCLR.
	write_reg "$SER_ADDR" 02ca 0x80
	write_reg "$SER_ADDR" 02c7 0x90
	sleep 0.1
	write_reg "$SER_ADDR" 02ca 0x90

	log "Configuring MAX96717 two-lane CSI input and tunnel pipe"

	# Known two-lane, non-continuous-clock CSI input configuration.
	write_reg "$SER_ADDR" 0308 0x64
	write_reg "$SER_ADDR" 0311 0x40
	write_reg "$SER_ADDR" 0330 0x40
	write_reg "$SER_ADDR" 0331 0x10
	write_reg "$SER_ADDR" 0332 0xe0
	write_reg "$SER_ADDR" 0333 0x04
	write_reg "$SER_ADDR" 0334 0x00
	write_reg "$SER_ADDR" 0335 0x00
	write_reg "$SER_ADDR" 0383 0x80

	# Critical fix: serializer tunnel stream ID must match deserializer pipe 0.
	write_reg "$SER_ADDR" 005b 0x00

	# Enable serializer video pipe 0.
	write_reg "$SER_ADDR" 0002 0x43
}

configure_deserializer()
{
	log "Configuring MAX96716A tunnel pipe and CSI Port A / DPHY0"

	# Disable CSI output while changing PHY and DPLL settings.
	write_reg "$DES_ADDR" 0313 0x00

	# Enable pipe 0 and select Link A stream 0.
	write_reg "$DES_ADDR" 0160 0x01
	write_reg "$DES_ADDR" 0161 0x20

	# Backtop / CSI setup retained from the known driver configuration.
	write_reg "$DES_ADDR" 0308 0x01
	write_reg "$DES_ADDR" 031d 0x2f
	write_reg "$DES_ADDR" 0320 0x29
	write_reg "$DES_ADDR" 0330 0x04

	# Enable Port A / DPHY0. The earlier 0xc4 value enabled only the wrong PHY.
	write_reg "$DES_ADDR" 0332 0xf4
	write_reg "$DES_ADDR" 0333 0x4e
	write_reg "$DES_ADDR" 0334 0xe4
	write_reg "$DES_ADDR" 0335 0x00
	write_reg "$DES_ADDR" 0336 0x00

	# Port-A DPHY timings and two-lane configuration.
	write_reg "$DES_ADDR" 0440 0x01
	write_reg "$DES_ADDR" 0443 0x01
	write_reg "$DES_ADDR" 0444 0x01
	write_reg "$DES_ADDR" 0445 0x71
	write_reg "$DES_ADDR" 0446 0x19
	write_reg "$DES_ADDR" 0447 0x1c
	write_reg "$DES_ADDR" 0449 0x01
	write_reg "$DES_ADDR" 044a 0x50

	# Critical fix: route tunnel pipe 0 to Port A / DPHY0.
	write_reg "$DES_ADDR" 0474 0x09

	# Restart the DPLL used by the known working Port-A state.
	write_reg "$DES_ADDR" 1d00 0xf4
	sleep 0.02
	write_reg "$DES_ADDR" 1d00 0xf5

	# Enable CSI output.
	write_reg "$DES_ADDR" 0313 0x02
}

load_sensor()
{
	local attempt

	local sensor_bus_id

	log "Loading the Link-A IMX708 alias overlay (${SENSOR_ADDR})"

	if ! dtoverlay -l 2>/dev/null | grep -qF "$OVERLAY_NAME"; then
		dtoverlay "$OVERLAY_NAME"
	fi

	sensor_bus_id="$(printf '%d-%04x' "$I2C_BUS" "$((SENSOR_ADDR))")"

	# A previous failed probe may leave the device present but unbound.
	if [[ -e "/sys/bus/i2c/devices/${sensor_bus_id}" &&
	      ! -e "/sys/bus/i2c/devices/${sensor_bus_id}/driver" ]]; then
		printf '%s\n' "$sensor_bus_id" > /sys/bus/i2c/drivers_probe
	fi

	for attempt in {1..50}; do
		if find /sys/class/video4linux -maxdepth 2 -name name \
			-exec grep -lqx imx708 {} \; 2>/dev/null |
			grep -q .; then
			break
		fi
		sleep 0.1
	done

	find_media_graph
	printf 'Media graph:   %s\n' "$MEDIA_DEV"
	printf 'RAW node:      %s\n' "$VIDEO_NODE"
	printf 'Sensor subdev: %s\n' "$SENSOR_NODE"
}

configure_media_graph()
{
	log "Selecting the direct RP1-CFE RAW path"

	# Disable all PiSP links. Some may already be disabled.
	media-ctl -d "$MEDIA_DEV" \
		--links '"csi2":1 -> "pisp-fe":0 [0]' || true
	media-ctl -d "$MEDIA_DEV" \
		--links '"rp1-cfe-fe-config":0 -> "pisp-fe":1 [0]' || true
	media-ctl -d "$MEDIA_DEV" \
		--links '"pisp-fe":2 -> "rp1-cfe-fe-image0":0 [0]' || true
	media-ctl -d "$MEDIA_DEV" \
		--links '"pisp-fe":4 -> "rp1-cfe-fe-stats":0 [0]' || true

	media-ctl -d "$MEDIA_DEV" \
		--links '"csi2":1 -> "rp1-cfe-csi2-ch0":0 [1]'

	media-ctl -d "$MEDIA_DEV" \
		--set-v4l2 \
		"\"imx708\":0/0 [fmt:SRGGB10_1X10/${WIDTH}x${HEIGHT} field:none]"
	media-ctl -d "$MEDIA_DEV" \
		--set-v4l2 \
		"\"csi2\":0/0 [fmt:SRGGB10_1X10/${WIDTH}x${HEIGHT} field:none]"
	media-ctl -d "$MEDIA_DEV" \
		--set-v4l2 \
		"\"csi2\":1/0 [fmt:SRGGB10_1X10/${WIDTH}x${HEIGHT} field:none]"

	if v4l2-ctl --device "$SENSOR_NODE" --list-ctrls 2>/dev/null |
		grep -q 'exposure'; then
		v4l2-ctl --device "$SENSOR_NODE" \
			--set-ctrl "exposure=${EXPOSURE}" || true
	fi

	if v4l2-ctl --device "$SENSOR_NODE" --list-ctrls 2>/dev/null |
		grep -q 'analogue_gain'; then
		v4l2-ctl --device "$SENSOR_NODE" \
			--set-ctrl "analogue_gain=${GAIN}" || true
	fi
}

show_status()
{
	local sensor_mode="unavailable"

	[[ -n "$MEDIA_DEV" ]] || find_media_graph

	log "Configuration status"
	printf 'Link-A padding:        '
	i2ctransfer -f -y "$I2C_BUS" "w1@${POT_ADDR}" 0x01 r1 || true
	printf 'MAX96716A ID:           '
	read_id "$DES_ADDR" || true
	printf 'MAX96716A link status:  '
	read_reg "$DES_ADDR" 0013 || true
	printf 'MAX96716A PHY enable:   '
	read_reg "$DES_ADDR" 0332 || true
	printf 'MAX96716A lane map:     '
	read_reg "$DES_ADDR" 0333 || true
	printf 'MAX96716A polarity:     '
	read_reg "$DES_ADDR" 0335 || true
	printf 'MAX96716A Port-A lanes: '
	read_reg "$DES_ADDR" 044a || true
	printf 'MAX96716A tunnel route: '
	read_reg "$DES_ADDR" 0474 || true
	printf 'MAX96716A CSI output:   '
	read_reg "$DES_ADDR" 0313 || true
	printf 'MAX96717 ID:            '
	read_id "$SER_ADDR" || true
	printf 'MAX96717 stream ID:     '
	read_reg "$SER_ADDR" 005b || true
	printf 'MAX96717 tunnel mode:   '
	read_reg "$SER_ADDR" 0383 || true

	if sensor_mode="$(
		i2ctransfer -f -y "$I2C_BUS" \
			"w2@${SENSOR_ADDR}" 0x01 0x00 r1 2>/dev/null
	)"; then
		printf 'IMX708 streaming:       %s\n' "$sensor_mode"
	fi

	printf '\nEnabled media links:\n'
	media-ctl -d "$MEDIA_DEV" -p |
		grep -E -- '-> .*\[(ENABLED|IMMUTABLE)' || true

	printf '\nPower status: '
	if command -v vcgencmd >/dev/null 2>&1; then
		vcgencmd get_throttled || true
	else
		printf 'vcgencmd unavailable\n'
	fi
}

capture_raw()
{
	local output="${1:-/tmp/imx708-port-a.raw}"
	local expected_size=$(( WIDTH * HEIGHT * 5 / 4 ))
	local actual_size

	[[ -n "$VIDEO_NODE" ]] || find_media_graph

	log "Capturing one ${WIDTH}x${HEIGHT} packed RAW10 buffer"
	rm -f -- "$output"

	timeout 10s v4l2-ctl \
		--verbose \
		--device "$VIDEO_NODE" \
		--set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=pRAA" \
		--stream-mmap=4 \
		--stream-count=1 \
		--stream-to="$output"

	[[ -f "$output" ]] || die "Capture did not create $output"
	actual_size="$(stat -c %s "$output")"

	printf 'Output:   %s\n' "$output"
	printf 'Size:     %s bytes\n' "$actual_size"
	printf 'Expected: %s bytes\n' "$expected_size"

	[[ "$actual_size" -eq "$expected_size" ]] ||
		die "RAW buffer has an unexpected size."
}

power_reset_camera()
{
	[[ "$CAMERA_POWER_RESET" == 1 ]] || return 0
	log "Power-resetting Link-A camera through INA226 ALERT"
	bash "$CAMERA_POWER_RESET_SCRIPT"
}

initialize_all()
{
	silence_link_b_video
	power_reset_camera
	configure_link
	configure_serializer
	configure_deserializer
	load_sensor
	configure_media_graph
	show_status
}

main()
{
	local action="${1:-all}"
	local output="${2:-/tmp/imx708-port-a.raw}"

	check_root
	check_tools

	case "$action" in
		init)
			initialize_all
			;;
		capture)
			find_media_graph
			configure_media_graph
			capture_raw "$output"
			;;
		status)
			modprobe i2c-dev
			show_status
			;;
		all)
			initialize_all
			capture_raw "$output"
			;;
		-h|--help|help)
			sed -n '2,20p' "$0"
			;;
		*)
			die "Unknown action '$action'. Use init, capture, status or all."
			;;
	esac
}

main "$@"
