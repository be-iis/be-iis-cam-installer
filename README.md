# BE-IIS Camera Installer

Linux integration for the BE-IIS Raspberry Pi GMSL2 camera platform.

```text
IMX708 → BE-IIS-GMSL2-SER (MAX96717)
       → GMSL2 Link A, 6 Gbit/s
       → BE-IIS-2CAM (MAX96716A)
       → CSI-2 Port A, 2 lanes
       → Raspberry Pi 5 CAM/DISP1
```

The repository contains the tested register initialization, a persistent
systemd service, the IMX708 horizontal-blanking driver patch, capture tools,
GStreamer helpers, diagnostics, and the legacy MAX96714 overlay work.

## Tested configuration

- Raspberry Pi 5
- BE-IIS-2CAM HAT with MAX96716A at I2C address `0x28`
- BE-IIS-GMSL2-SER sensor head with MAX96717 at `0x40`
- Sony IMX708 at `0x1a`
- TPL0102-100 digital potentiometer at `0x51`
- Linux I2C bus 11
- CAM/DISP1
- 2304 × 1296, packed RAW10, two CSI-2 lanes
- 450 MHz CSI-2 clock (900 Mbit/s per lane using DDR)

The 2304 × 1296 mode needs more horizontal blanking through this GMSL2
pipeline. The included driver patch changes `LINE_LENGTH_PCK` from `0x1e90`
to the tested, conservative value `0x2000`.

## Quick start

Install build and runtime dependencies:

```bash
sudo apt update
sudo apt install -y \
    build-essential curl patch raspberrypi-kernel-headers \
    i2c-tools media-ctl v4l-utils device-tree-compiler \
    rpicam-apps python3-numpy python3-opencv \
    gstreamer1.0-tools gstreamer1.0-libcamera \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad
```

Run the complete installation:

```bash
make all
```

This command:

1. downloads and patches the IMX708 driver matching the running kernel;
2. builds and installs `imx708.ko`;
3. installs the BE-IIS initialization and capture tools;
4. enables `dtparam=i2c_arm=on` in `/boot/firmware/config.txt`;
5. installs `i2c-dev` for boot;
6. enables the one-shot initialization service.

It **does not reboot**. Reboot explicitly when convenient:

```bash
sudo reboot
```

After reboot:

```bash
systemctl status be-iis-camera-init.service
sudo beiis-camera-init status
```

## Capture

Still image with the 3 MP profile:

```bash
beiis-capture-image --megapixels 3 --output image.jpg
```

Still image plus DNG:

```bash
beiis-capture-image --megapixels 3 --raw --output image.jpg
```

MJPEG video (portable Raspberry Pi 5 default):

```bash
beiis-capture-video --megapixels 3 --duration 10 --output video.mjpeg
```

H.264 can still be selected explicitly with `--codec h264` when a suitable
encoder is installed.

GStreamer live preview:

```bash
beiis-gst-preview --megapixels 3
```

GStreamer recording:

```bash
beiis-gst-record --megapixels 3 --duration 10 --output video.mp4
```

Available named resolution profiles are `1`, `3`, and `12` megapixels.
Explicit `WIDTHxHEIGHT` values are accepted as well.

## Development workflow

The IMX708 driver package supports the requested staged workflow:

```bash
make prepare
make fetch
make patch
make
make install
```

Or run all build and installation steps:

```bash
make all
```

No target reboots the Pi.

## Repository layout

```text
config/                         boot and module configuration
docs/                           installation and troubleshooting
drivers/imx708/                 reproducible external-module build and patch
hardware/                       board-specific documentation
overlays/                       Device Tree sources, including legacy work
profiles/be-iis-2cam-imx708/    tested MAX96716A/MAX96717/IMX708 setup
systemd/                        one-shot boot initialization
tools/capture/                  rpicam image and video tools
tools/gstreamer/                preview and recording pipelines
tools/raw/                      packed RAW10 conversion
```

## Important notes

- The active MAX96716A configuration is initialized through I2C. It does not
  depend on the legacy MAX96714 overlay.
- Dynamic overlay loading can emit Device Tree overlay removal warnings.
  Persistent boot integration should eventually move the complete topology
  into a dedicated production overlay.
- A historical `get_throttled=0x50000` indicates past undervoltage even when
  the current supply is stable. Use a reliable 5 V supply.
- Back up a known-good register dump before changing serializer or
  deserializer timing.

See [Installation](docs/installation.md) and
[Troubleshooting](docs/troubleshooting.md) for details.

## Current bring-up status

- Link A uses the MAX96717 I2C alias `0x52` and is stable at 2304×1296 with padding value `0xba`.
- Link B is not connected during this validated Link-A configuration.
