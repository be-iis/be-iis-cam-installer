#!/usr/bin/env bash
#
# Bring up:
#   IMX708 -> MAX96717 -> GMSL2 Link B (6Gbit/s)
#          -> MAX96716A hardware pipe 1 -> DPHY1 -> Raspberry Pi 5 CSI1
#
# This is the Link-B counterpart to init-imx708-gmsl-port-a-tunnel.sh.
# It retains the proven Link-A serializer sequence. Link B selects logical
# pipe 1, which is received by MAX96716A hardware pipe 1 (not pipe 2).
#
# Validated bring-up state (2026-07-28):
# - IMX708 is detected on I2C-11 and CSI1.
# - Sensor streaming, serializer PCLK detection and MAX96716A hardware-pipe-1
#   video lock are active.
# - Link B was captured successfully through hardware pipe 1 / DPHY0 / CSI0.
# - Raspberry Pi CSI1 still receives no frames when that same pipe is routed
#   to DPHY1. Investigate the DPHY1-to-CSI1 hardware path separately.
#   This is not yet a production configuration.
#
# Usage:
#   sudo ./init-imx708-gmsl-port-b-tunnel.sh init
#   sudo ./init-imx708-gmsl-port-b-tunnel.sh status
#
# Environment overrides:
#   I2C_BUS=11 DES_ADDR=0x28 SER_ADDR=0x40 POT_ADDR=0x51 SENSOR_ADDR=0x1a

set -Eeuo pipefail

I2C_BUS="${I2C_BUS:-11}"
DES_ADDR="${DES_ADDR:-0x28}"
SER_ADDR="${SER_ADDR:-0x40}"
POT_ADDR="${POT_ADDR:-0x51}"
SENSOR_ADDR="${SENSOR_ADDR:-0x1a}"

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
	local address="$1" reg="$2" value="$3"

	i2ctransfer -f -y "$I2C_BUS" \
		"w3@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" "$value"
}

read_reg()
{
	local address="$1" reg="$2"

	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${address}" \
		"0x${reg:0:2}" "0x${reg:2:2}" r1
}

read_id()
{
	i2ctransfer -f -y "$I2C_BUS" "w2@$1" 0x00 0x0d r2
}

check_root()
{
	(( EUID == 0 )) || die "Run this script with sudo."
}

check_tools()
{
	need_cmd i2ctransfer
	need_cmd modprobe
}

configure_link()
{
	local serializer_id="" attempt

	log "Loading I2C support"
	modprobe i2c-dev
	[[ -e "/dev/i2c-${I2C_BUS}" ]] ||
		die "/dev/i2c-${I2C_BUS} does not exist."

	log "Configuring DigiPot channel A for Link B"
	i2ctransfer -f -y "$I2C_BUS" "w2@${POT_ADDR}" 0x00 0xae

	log "Configuring MAX96716A Link B for GMSL2 6Gbit/s over coax"
	write_reg "$DES_ADDR" 0004 0x02
	write_reg "$DES_ADDR" 0011 0x0f
	write_reg "$DES_ADDR" 0013 0x01
	sleep 0.1
	write_reg "$DES_ADDR" 0013 0x00

	for attempt in {1..30}; do
		sleep 0.1
		serializer_id="$(read_id "$SER_ADDR" 2>/dev/null || true)"
		[[ "$serializer_id" == "0xbf 0x06" ]] && break
	done

	printf 'MAX96716A Link-B status: '
	read_reg "$DES_ADDR" 5009
	printf 'MAX96717 ID/revision:    %s\n' "${serializer_id:-unavailable}"
	[[ "$serializer_id" == "0xbf 0x06" ]] ||
		die "MAX96717 on Link B did not become reachable."
}

configure_serializer()
{
	log "Configuring MAX96717 clock, camera power/reset and CSI input"

	# Same ordering and values as the validated Link-A path.
	write_reg "$SER_ADDR" 0002 0x03
	write_reg "$SER_ADDR" 056f 0x0e
	write_reg "$SER_ADDR" 0003 0x07
	write_reg "$SER_ADDR" 03f0 0x5a
	write_reg "$SER_ADDR" 03f0 0x59
	write_reg "$SER_ADDR" 0006 0xb0

	write_reg "$SER_ADDR" 0042 0xa4
	write_reg "$SER_ADDR" 0043 0x34
	write_reg "$SER_ADDR" 0044 0x00
	write_reg "$SER_ADDR" 0045 0x00

	write_reg "$SER_ADDR" 02ca 0x80
	write_reg "$SER_ADDR" 02c7 0x90
	sleep 0.1
	write_reg "$SER_ADDR" 02ca 0x90

	write_reg "$SER_ADDR" 0308 0x64
	write_reg "$SER_ADDR" 0311 0x40
	write_reg "$SER_ADDR" 0330 0x40
	write_reg "$SER_ADDR" 0331 0x10
	write_reg "$SER_ADDR" 0332 0xe0
	write_reg "$SER_ADDR" 0333 0x04
	write_reg "$SER_ADDR" 0334 0x00
	write_reg "$SER_ADDR" 0335 0x00
	write_reg "$SER_ADDR" 0383 0x80

	# MAX96717 hardware pipe 2, stream 0: retained from Link A.
	write_reg "$SER_ADDR" 005b 0x00
	write_reg "$SER_ADDR" 0002 0x43

	printf 'IMX708 ID/revision:      '
	i2ctransfer -f -y "$I2C_BUS" \
		"w2@${SENSOR_ADDR}" 0x00 0x16 r2
}

configure_deserializer()
{
	log "Configuring MAX96716A tunnel pipe and CSI Port B / DPHY1"

	# Same shared back-top / PHY baseline as Link A.
	write_reg "$DES_ADDR" 0313 0x00
	# Logical pipe 1 is selected for Link B in 0x0161; enable pipe 1.
	write_reg "$DES_ADDR" 0160 0x02
	write_reg "$DES_ADDR" 0161 0x20
	write_reg "$DES_ADDR" 0308 0x01
	write_reg "$DES_ADDR" 031d 0x2f
	write_reg "$DES_ADDR" 0320 0x29
	write_reg "$DES_ADDR" 0330 0x04
	write_reg "$DES_ADDR" 0332 0xf4
	write_reg "$DES_ADDR" 0333 0x4e
	# DPHY1 PCB routing swaps D0 and D1 relative to the MAX96716A default.
	write_reg "$DES_ADDR" 0334 0xe1
	write_reg "$DES_ADDR" 0335 0x00
	write_reg "$DES_ADDR" 0336 0x00

	# Configure DPHY1 for a two-lane output.
	write_reg "$DES_ADDR" 0480 0x01
	write_reg "$DES_ADDR" 0483 0x01
	write_reg "$DES_ADDR" 0484 0x01
	write_reg "$DES_ADDR" 0485 0x71
	write_reg "$DES_ADDR" 0486 0x19
	write_reg "$DES_ADDR" 0487 0x1c
	write_reg "$DES_ADDR" 0489 0x01
	write_reg "$DES_ADDR" 048a 0x50

	# DPHY1 uses its own DPLL control and reset registers.
	write_reg "$DES_ADDR" 0323 0x29
	write_reg "$DES_ADDR" 1e00 0xf4
	sleep 0.02
	write_reg "$DES_ADDR" 1e00 0xf5

	# Link B arrives at MAX96716A hardware pipe 1 (0x021c video lock).
	# 0x0474 routes this active pipe; bit 1 selects DPHY1.
	write_reg "$DES_ADDR" 0474 0x0b
	write_reg "$DES_ADDR" 0313 0x02
}

show_status()
{
	log "Configuration status"
	printf 'MAX96716A Link-B status: '
	read_reg "$DES_ADDR" 5009 || true
	printf 'MAX96716A pipe enable:   '
	read_reg "$DES_ADDR" 0160 || true
	printf 'MAX96716A pipe select:   '
	read_reg "$DES_ADDR" 0161 || true
	printf 'MAX96716A DPHY1 lanes:   '
	read_reg "$DES_ADDR" 048a || true
	printf 'MAX96716A Pipe1 route:   '
	read_reg "$DES_ADDR" 0474 || true
	printf 'MAX96716A Pipe1 lock:    '
	read_reg "$DES_ADDR" 021c || true
	printf 'MAX96716A CSI output:    '
	read_reg "$DES_ADDR" 0313 || true
	printf 'MAX96717 stream ID:      '
	read_reg "$SER_ADDR" 005b || true
	printf 'MAX96717 PCLK detect:    '
	read_reg "$SER_ADDR" 0112 || true
	printf 'MAX96717 tunnel mode:    '
	read_reg "$SER_ADDR" 0383 || true
	printf 'IMX708 streaming:        '
	read_reg "$SENSOR_ADDR" 0100 || true
}

initialize_all()
{
	configure_link
	configure_serializer
	configure_deserializer
	show_status
}

main()
{
	local action="${1:-init}"

	check_root
	check_tools

	case "$action" in
		init)
			initialize_all
			;;
		status)
			modprobe i2c-dev
			show_status
			;;
		-h|--help|help)
			sed -n '2,16p' "$0"
			;;
		*)
			die "Unknown action '$action'. Use init or status."
			;;
	esac
}

main "$@"
