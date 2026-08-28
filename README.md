# BE-IIS Camera Installer

Linux integration for the BE-IIS Raspberry Pi GMSL2 camera platform.

The current branch is intentionally a **manual bring-up** environment: no
systemd service is installed or used. The scripts make each control-plane,
overlay and video step visible and repeatable.

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
make cameras-a-b
make a-b

rpicam-hello --list-cameras
rpicam-hello --camera 0 -t 0 --width 2304 --height 1296
rpicam-hello --camera 1 -t 0 --width 2304 --height 1296
~~~

Use Ctrl-C to stop one preview before starting the other.

- make init-a-b configures both reverse-I2C links and sensor/focus aliases.
- make cameras-a-b runs that setup and loads the two IMX708 overlays.
- make a-b configures both serializers and both deserializer CSI outputs.
- make a remains the single-Link-A video sequence.
- make unoverlay removes only the dynamically loaded BE-IIS overlays.

The dual I2C-mux module is experimental and is not part of this video workflow.

For the detailed, human-readable procedure, see
[Dual-camera manual bring-up](docs/dual-camera-bringup.md). For the compact
technical baseline used by future debugging work, see
[AI dual-camera reference](docs/ai-dual-camera-reference.md).

## Driver build

Build and install the patched IMX708 module for the running kernel:

~~~bash
make driver
~~~

No target reboots the Pi. Reboot manually only when needed after a kernel or
module update.

## Requirements

~~~bash
sudo apt update
sudo apt install -y build-essential raspberrypi-kernel-headers \
  i2c-tools media-ctl v4l-utils device-tree-compiler rpicam-apps
~~~

## Repository layout

~~~text
drivers/imx708/                 reproducible external IMX708 module build
drivers/max96716a-i2c-mux/       experimental control-plane I2C mux
overlays/                        dual IMX708 Device Tree sources
tools/init-gmsl-*.sh             manual reverse-I2C setup
tools/bringup-gmsl-*.sh          manual CSI/video setup
docs/                            procedure and diagnostic references
~~~
