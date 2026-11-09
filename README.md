# BE-IIS GMSL2 camera installer for Raspberry Pi 4

This experimental branch targets Raspberry Pi 4 Model B, the BE-IIS GMSL2 2CAM
Rev. B HAT and one IMX708 camera connected through a MAX96717 serializer.
The Pi 4 has one 15-pin camera connector with two CSI-2 data lanes. Use an
appropriate 15-to-22-pin camera ribbon cable between the Pi's CAMERA connector
and the HAT's CSI output for Link A. Connect the serializer to the HAT's GMSL
Link A coax input and power the hardware as specified for the HAT and serializer.

Link A uses the Pi's CSI1 (Unicam), the camera I²C bus at `/dev/i2c-10`, and
camera index 0. The IMX708 and autofocus aliases are `0x52` and `0x5c`.
This setup uses the existing two-lane tunnel configuration and the Raspberry Pi
OS libcamera pipeline. The [main branch](https://github.com/be-iis/be-iis-cam-installer)
contains the Pi 5 dual-camera setup.

## Install and bring up Link A

On Raspberry Pi OS with a supported Raspberry Pi kernel and matching headers:

```bash
git clone --branch pi4-2lane https://github.com/be-iis/be-iis-cam-installer.git
cd be-iis-cam-installer
./install.sh
```

If the installer changes the boot configuration, it reboots the Pi. Run
`./install.sh` again after reboot. Then run:

```bash
make prepare-a
rpicam-hello --list-cameras
rpicam-hello --camera 0 --nopreview --timeout 5000 --width 2304 --height 1296
```

`make prepare-a` initializes the control path and aliases, configures the
serializer and deserializer video pipeline, and loads the Link A overlay.
Stop any camera applications and run `make unoverlay` before repeating
`make prepare-a`. Use `make video` for live preview or `make png` for a still.

For a transport-only check with a powered serializer and no image sensor,
run `make init-a SENSOR=no`. This checks GMSL2 lock. Video capture on the
Pi 4 still requires validation on hardware.
