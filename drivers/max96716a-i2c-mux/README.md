# MAX96716A dual-link I²C Address Translator

Minimal kernel module for the BE-IIS dual-camera HAT.

Both remote IMX708 sensors have physical address `0x1a`. The Raspberry Pi
6.12 kernel supplies I²C-ATR headers but does not export the I²C-ATR core to
external modules. Therefore this module contains the fixed two-link mapping
required by this board:

| Child bus | Remote address | MAX96717 alias |
| --- | --- | --- |
| Link A | `0x1a` | `0x54` |
| Link B | `0x1a` | `0x55` |

The module configures those aliases and keeps both MAX96716A reverse-control
channels enabled. Applications address each camera as `0x1a` on its own
child bus.

It does **not** configure video, CSI, media entities, overlays or camera
drivers.

Build/install and test:

    sudo modprobe -r beiis_max96716a_i2c_mux 2>/dev/null || true
    make i2c-mux-driver

    make init-a
    make init-b
    sudo modprobe beiis_max96716a_i2c_mux
    i2cdetect -l

The module creates two additional I²C adapters (their numbers are dynamic,
usually 30 and 31). Obtain them from the channel symlinks:

    A=$(basename "$(readlink -f /sys/bus/i2c/devices/11-0028/channel-0)" | sed 's/i2c-//')
    B=$(basename "$(readlink -f /sys/bus/i2c/devices/11-0028/channel-1)" | sed 's/i2c-//')
    echo "Link A: i2c-$A; Link B: i2c-$B"

Probe both cameras directly; no `new_device` step is needed:

    sudo i2ctransfer -f -y "$A" w2@0x1a 0x00 0x16 r2
    sudo i2ctransfer -f -y "$B" w2@0x1a 0x00 0x16 r2

Both probes should return `0x07 0x08`.

Unload the helper:

    sudo modprobe -r beiis_max96716a_i2c_mux
