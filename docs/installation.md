# Installation

Run the installer on the Raspberry Pi:

```bash
./install.sh
```

On a fresh system the installer first checks whether the camera I2C bus
(`/dev/i2c-11`) is available. If it is missing, the installer enables the
required Raspberry Pi camera I2C setting (`dtparam=i2c_csi_dsi=on`) and
reboots the Pi. Run `./install.sh` again after the reboot.

The installer then installs the required build, I2C, V4L2, rpicam, Python and
GStreamer packages and builds/installs both external kernel modules:

- patched IMX708 driver
- MAX96716A I2C mux driver

A custom kernel must provide `/lib/modules/$(uname -r)/build`.

Installation does **not** initialise the GMSL links or video pipelines.
Those steps remain explicit and manual.

For the validated two-camera setup:

```bash
make unoverlay
make prepare-a-b
make pipeline-a-b
```

Then verify camera discovery:

```bash
rpicam-hello --list-cameras
```

Useful preview/capture targets:

```bash
make png-0
make png-1
make video-0
make video-1
make video-dual
```

See [Dual-camera manual bring-up](dual-camera-bringup.md) for the complete
procedure and diagnostics.
