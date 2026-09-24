# Installation

Run the installer on the Raspberry Pi:

```bash
./install.sh imx708-revb
```

On a fresh system the installer first checks whether the camera I2C bus
(`/dev/i2c-11`) is available. If it is missing, the installer enables the
required Raspberry Pi camera I2C setting (`dtparam=i2c_csi_dsi=on`) and
reboots the Pi. Run the same installer command again after the reboot.

The installer then installs the required build, I2C, V4L2, rpicam, Python and
GStreamer packages and installs the selected profile's driver and overlays.
For `imx708-revb`, it installs:

- patched IMX708 driver
- MAX96716A I2C mux driver
- the two IMX708 overlays (without loading them)

A custom kernel must provide `/lib/modules/$(uname -r)/build`.

Installation does **not** initialise the GMSL links or video pipelines.
Those steps remain explicit and manual.

For the validated two-camera setup:

```bash
make unoverlay
make prepare-a-b PROFILE=imx708-revb
make pipeline-a-b PROFILE=imx708-revb
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

Without an argument, `./install.sh` selects `imx708-revb`. The `make` targets
use the same default. The older names `make cameras-a-b` and `make a-b` remain
aliases for `prepare-a-b` and `pipeline-a-b`.
