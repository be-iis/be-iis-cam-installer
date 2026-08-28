# Dual-Link I²C Address Translator

Minimal kernel module for the BE-IIS dual-camera HAT.

The remote IMX708 sensors both have native I²C address `0x1a`. The two
manual bring-up scripts configure the serializer aliases first:

| Link | Native sensor address | Serializer alias |
| --- | --- | --- |
| A | `0x1a` | `0x52` |
| B | `0x1a` | `0x53` |

At the end of `make init-b`, both MAX96716A reverse-I²C channels are
enabled. This module does **not** touch SerDes registers. It only creates one
Linux I²C bus per link and changes the native address `0x1a` to the
respective preconfigured alias.

It does **not** configure video, CSI, media entities, overlays or camera
drivers.

Build and test:

    sudo modprobe -r beiis_max96716a_i2c_mux 2>/dev/null || true
    make i2c-mux-driver

    make init-a
    make init-b
    sudo modprobe beiis_max96716a_i2c_mux

Find the dynamically allocated child buses by their names:

    for d in /sys/class/i2c-adapter/i2c-*; do
        n=$(cat "$d/name")
        case "$n" in
            "BE-IIS GMSL Link A") A=${d##*-} ;;
            "BE-IIS GMSL Link B") B=${d##*-} ;;
        esac
    done
    echo "Link A: i2c-$A; Link B: i2c-$B"

Probe both cameras independently:

    sudo i2ctransfer -f -y "$A" w2@0x1a 0x00 0x16 r2
    sudo i2ctransfer -f -y "$B" w2@0x1a 0x00 0x16 r2

Both probes should return `0x07 0x08`.

Unload the helper:

    sudo modprobe -r beiis_max96716a_i2c_mux
