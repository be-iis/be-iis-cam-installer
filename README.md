# BE-IIS Camera Installer

Build and installation tools for a Raspberry Pi GMSL2 camera pipeline based on:

```text
Sony IMX708 -> MAX96717F -> GMSL2 -> MAX96714F -> Raspberry Pi CSI-2
```

## Supported configuration

- Raspberry Pi kernel 6.12 or newer
- MAX96714F deserializer at Linux 7-bit I2C address `0x28`
  (`0x50` in Maxim 8-bit notation)
- MAX96717F serializer at Linux 7-bit I2C address `0x40`
  (CFG pulled down)
- Sony IMX708 sensor at `0x1a`
- two CSI-2 data lanes at 450 MHz
- MAX96717 MFP3 as camera enable
- MAX96717 MFP4 as IMX708 XCLR/reset
- optional DW9817 autofocus controller at `0x0c`

## Installation

Install the basic build tools and the matching Raspberry Pi kernel headers:

```bash
sudo apt update
sudo apt install -y build-essential wget patch device-tree-compiler raspberrypi-kernel-headers
```

Clone the repository and run:

```bash
chmod +x install.sh
./install.sh
```

The installer builds and installs all three kernel modules and the Device Tree
overlay. It does not modify `config.txt` automatically.

Add this line to `/boot/firmware/config.txt` for CAM/DISP1:

```text
dtoverlay=max96714-max96717-imx708
```

For CAM/DISP0 use:

```text
dtoverlay=max96714-max96717-imx708,cam0
```

Reboot the Raspberry Pi after changing `config.txt`.

## Important limitations

The current MAX96714 Linux driver does not expose the deserializer MFP pins as
a GPIO controller. The overlay therefore controls MAX96717 MFP3 and MFP4
directly through the GMSL2 I2C control channel. MAX96714 MFP7 through MFP10 are
not configured by this version.

The MAX96717 build applies a clearly marked local patch for a GPIO callback
that otherwise ignores low output values. This patch is not yet an accepted
upstream Linux patch and must be validated on the target hardware.

## Project structure

```text
be-iis-cam-installer/
├── README.md
├── install.sh
├── tools/
│   ├── README.md
│   └── kernel/
│       ├── README.md
│       ├── imx708_mod_build.sh
│       ├── max96714_mod_build.sh
│       ├── max96717_mod_build.sh
│       └── patches/
│           ├── README.md
│           └── max96717-gpio-set-value.patch
└── overlays/
    ├── README.md
    ├── max96714-max96717-imx708-overlay.dts
    └── build_install_overlay.sh
```
