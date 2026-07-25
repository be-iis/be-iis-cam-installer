# BE-IIS-2CAM with BE-IIS-GMSL2-SER and IMX708

`init.sh` is the known-good I2C initialization for:

- MAX96716A on Link A at `0x28`;
- MAX96717 at `0x40`;
- IMX708 at `0x1a`;
- TPL0102-100 at `0x51`;
- CSI-2 Port A / DPHY0 to Raspberry Pi 5 CAM/DISP1.

The default action initializes the complete chain and captures one RAW frame:

```bash
sudo ./init.sh all /tmp/frame.raw
```

For systemd, use initialization only:

```bash
sudo ./init.sh init
```

Status and direct RAW capture:

```bash
sudo ./init.sh status
sudo ./init.sh capture /tmp/frame.raw
```

Environment variables such as `I2C_BUS`, `WIDTH`, `HEIGHT`, `EXPOSURE`, and
`GAIN` can override the defaults.
