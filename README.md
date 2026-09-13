# BE-IIS Camera Installer

Linux integration for the BE-IIS Raspberry Pi GMSL2 camera platform.

The repository intentionally keeps installation, GMSL control-plane setup,
video-pipeline setup and user capture commands separate. No systemd service
initialises the cameras automatically.

## Installation

On a fresh Raspberry Pi run:

~~~bash
./install.sh
~~~

The installer:

1. checks for the Raspberry Pi camera I2C bus (`/dev/i2c-11`),
2. enables `dtparam=i2c_csi_dsi=on` when required and reboots,
3. installs the build, I2C, V4L2, rpicam, Python and GStreamer dependencies,
4. builds and installs the patched IMX708 driver,
5. builds and installs the MAX96716A I2C mux driver.

After an automatic reboot, run `./install.sh` again. Installation does **not**
initialise a GMSL link or video pipeline.

## Current verified dual-camera configuration

| Link | Aliases | MAX96716A output | Raspberry Pi input | rpicam camera |
| --- | --- | --- | --- | --- |
| A | IMX708 0x52, DW9807 0x5c | Port A / DPHY0-1 | CSI1 (1f00128000.csi) | 1 |
| B | IMX708 0x53, DW9807 0x5d | Port B / DPHY2-3 | CSI0 / J3 (1f00110000.csi) | 0 |

Validated mode: 2304x1296, RAW10, two CSI-2 lanes, 900 Mbit/s per lane.

## Manual dual-camera workflow

~~~bash
cd ~/be-iis-cam-installer
make unoverlay
make prepare-a-b
make pipeline-a-b
rpicam-hello --list-cameras
~~~

The steps are deliberately separate:

- `make init-a` initialises only the Link-A control path.
- `make init-b` initialises only the Link-B control path.
- `make init-a-b` initialises both reverse-I2C links and aliases.
- `make prepare-a-b` runs the dual control-plane setup and loads both IMX708 overlays.
- `make pipeline-a` configures the Link-A GMSL/CSI video pipeline.
- `make pipeline-a-b` configures both serializers and deserializer CSI outputs.
- `make unoverlay` removes only dynamically loaded BE-IIS camera overlays.

The previous short targets `make a`, `make a-b` and `make cameras-a-b` remain
as compatibility aliases but should not be used in new instructions.

## Capture and preview

Save a PNG:

~~~bash
make png-0
make png-1
~~~

The files are written to `captures/` with a timestamp. The generic form is
`make png CAMERA=0` or `make png CAMERA=1`.

Show one camera continuously on the local display:

~~~bash
make video-0
make video-1
~~~

The generic form is `make video CAMERA=0` or `make video CAMERA=1`. Stop with
Ctrl-C.

Show both cameras side by side on HDMI:

~~~bash
make video-dual
~~~

On the validated dual setup, rpicam camera 0 is Link B (`imx708@53`) and camera
1 is Link A (`imx708@52`).

For the detailed manual procedure, see
[Dual-camera manual bring-up](docs/dual-camera-bringup.md). For the compact
technical baseline used by future debugging work, see
[AI dual-camera reference](docs/ai-dual-camera-reference.md).

## Driver build

The individual driver targets remain available:

~~~bash
make driver
make i2c-mux-driver
~~~

## Repository layout

~~~text
drivers/imx708/                  reproducible external IMX708 module build
drivers/max96716a-i2c-mux/       MAX96716A control-plane I2C mux
overlays/                         dual IMX708 Device Tree sources
tools/init-gmsl-*.sh             manual reverse-I2C setup
tools/bringup-gmsl-*.sh          manual CSI/video-pipeline setup
examples/                         capture/preview examples
docs/                             procedure and diagnostic references
~~~
