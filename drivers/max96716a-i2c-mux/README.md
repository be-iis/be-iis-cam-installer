# MAX96716A I2C mux

Minimal kernel module for the BE-IIS dual-camera HAT.

It creates two virtual I2C buses behind the Pi's I2C-11 bus:

- i2c-30: physical Link A
- i2c-31: physical Link B

The module selects the MAX96716A reverse control path immediately before each
child-bus transaction. It does not configure video, CSI, media entities,
overlays, or camera drivers.

Build/install:

    make i2c-mux-driver

Manual bring-up must have powered and reset both remote IMX708 sensors first:

    make init-a
    make init-b
    sudo modprobe beiis_max96716a_i2c_mux

Probe the native IMX708 address separately on each virtual bus:

    sudo i2ctransfer -f -y 30 w2@0x1a 0x00 0x16 r2
    sudo i2ctransfer -f -y 31 w2@0x1a 0x00 0x16 r2

Both probes should return 0x07 0x08.
