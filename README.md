# BE-IIS Camera Installer

Linux integration for the BE-IIS Raspberry Pi GMSL2 camera platform.

The repository intentionally keeps installation, GMSL control-plane setup,
video-pipeline setup and user capture commands separate. No systemd service
initialises the cameras automatically.

## Installation

On a fresh Raspberry Pi run (the default profile is `imx708-revb`):

~~~bash
./install.sh
# Equivalent: ./install.sh imx708-revb
~~~

The installer:

1. checks for the Raspberry Pi camera I2C bus (`/dev/i2c-11`),
2. enables `dtparam=i2c_csi_dsi=on` when required and reboots,
3. installs the build, I2C, V4L2, rpicam, Python and GStreamer dependencies,
4. builds and installs the driver specified by the camera profile,
5. builds and installs the MAX96716A I2C mux driver,
6. compiles and installs that profile's camera overlays without activating them.

After an automatic reboot, run `./install.sh` again. Installation does **not**
initialise a GMSL link or video pipeline.

## Camera profiles

`profiles/imx708-revb.json` records the hardware combination, I2C aliases,
sensor ID checks, power sequence and ordered serializer/deserializer pipeline
register writes. `tools/camera_profile.py` accepts only known operations
(`write`, masked `update`, bounded `sleep`); JSON cannot execute shell code.
Each register step has a `description` explaining its purpose. For settings
whose individual register bits have not yet been confirmed, the description
explicitly says so. After each link reset, the profile enables and verifies
MAX96716A receiver adaptation (RLMS3 `AdaptEn`, `0x1403` on A and `0x1503`
on B). This enables adaptation; it does not set a fixed equalizer coefficient.
Profile selection is explicit: `./install.sh PROFILE` followed by
`make prepare-a-b PROFILE=PROFILE` and `make pipeline-a-b PROFILE=PROFILE`.
The migrated IMX708 profile needs a Raspberry Pi hardware retest before
production use.

To add a camera, provide a reviewed JSON profile, a sensor driver Make target
(or `none` for an existing kernel driver), and two overlay DTS files. Mark a
new profile `verified` only after checking sensor IDs and image capture on the
actual hardware. Sensor driver patches remain profile specific. The older
IMX708 shell scripts remain in `tools/` for comparison and manual recovery.

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
- `make prepare-a-b` runs the selected profile's dual control-plane setup and loads its camera overlays.
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
