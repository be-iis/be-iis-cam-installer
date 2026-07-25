# Legacy MAX96714 Device Tree overlay

> This directory describes the earlier MAX96714 topology. It is retained for
> reference and is not installed by the root `make all` target. The tested
> BE-IIS-2CAM/MAX96716A profile is initialized through I2C from
> `profiles/be-iis-2cam-imx708/init.sh`.

`max96714-max96717-imx708-overlay.dts` describes this pipeline:

```text
IMX708 -> MAX96717F -> GMSL2 -> MAX96714F -> Raspberry Pi CSI-2
```

Build and install it with:

```bash
./build_install_overlay.sh
```

Default configuration:

- CAM/DISP1 (`cam0` selects CAM/DISP0)
- MAX96714F: Linux address `0x28`
- MAX96717F: Linux address `0x40`
- IMX708: address `0x1a`
- two CSI-2 lanes at 450 MHz
- MAX96717 MFP3: camera enable
- MAX96717 MFP4: IMX708 XCLR/reset
- DW9817 autofocus enabled

The remote camera board must provide the actual sensor supply rails. The
overlay models MFP3 as a fixed-regulator enable signal.

The MAX96714 MFP7-MFP10 assignments are not implemented because the current
MAX96714 Linux driver does not provide GPIO forwarding support.
