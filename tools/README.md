# Tools

## ADI kernel

- `adi/clone-adi-linux.sh`: clone the supported ADI GMSL kernel branch.
- `adi/build-install-kernel.sh`: configure, patch, build and install the
  complete Raspberry Pi 5 ADI GMSL kernel.
- `adi/patches/0001-media-imx708-handle-reset-gpio-errors.patch`: stop IMX708
  probe cleanly when its reset GPIO provider returns an error.

## MAX96716A CFG1

`set-cfg1-ratio.sh` programs channel B of the TPL0102-100 digital
potentiometer and stores the value in EEPROM.

Example:

```bash
./set-cfg1-ratio.sh --ratio 67.95 --i2c-device 11
```
