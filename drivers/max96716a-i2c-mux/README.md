# MAX96716A dual-link I²C Address Translator

Minimal kernel module for the BE-IIS dual-camera HAT.

Both remote IMX708 sensors have physical address `0x1a`. This module uses
the Linux **I²C-ATR** framework: it exposes one child bus per GMSL link and
programs a different MAX96717 address-translation alias for every child-bus
device. Both reverse control channels can then remain enabled at the same time.

It does **not** configure video, CSI, media entities, overlays or camera
drivers.

Build/install:

    make i2c-mux-driver

Prepare both links, then load the module:

    make init-a
    make init-b
    sudo modprobe beiis_max96716a_i2c_mux
    i2cdetect -l

The module creates two additional I²C adapters (their numbers are dynamic;
they are commonly 30 and 31). First create one temporary child device at the
native IMX708 address on each adapter. This makes I²C-ATR allocate aliases and
program them into the matching serializer:

    echo "dummy 0x1a" | sudo tee /sys/bus/i2c/devices/i2c-30/new_device
    echo "dummy 0x1a" | sudo tee /sys/bus/i2c/devices/i2c-31/new_device

Replace `30` and `31` with the actual child-bus numbers. Then probe each
sensor independently:

    sudo i2ctransfer -f -y 30 w2@0x1a 0x00 0x16 r2
    sudo i2ctransfer -f -y 31 w2@0x1a 0x00 0x16 r2

Both probes should return `0x07 0x08`. The logs show the local aliases used
by ATR (currently taken from `0x54`–`0x57`); applications still address
`0x1a` on their respective child bus.

Remove the two temporary devices before unloading:

    echo 0x1a | sudo tee /sys/bus/i2c/devices/i2c-30/delete_device
    echo 0x1a | sudo tee /sys/bus/i2c/devices/i2c-31/delete_device
    sudo modprobe -r beiis_max96716a_i2c_mux
