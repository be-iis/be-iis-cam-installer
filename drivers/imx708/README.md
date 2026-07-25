# IMX708 GMSL2 horizontal-blanking patch

The 2304 × 1296 mode was tested across the BE-IIS GMSL2 chain with several
line lengths:

- `0x1e90`: corrupt lower image region;
- `0x1f00`: first tested clean value;
- `0x2000`: selected production value with additional margin.

The patch updates both the IMX708 register list and the driver's
`line_length_pix` description. This keeps the V4L2 HBLANK control consistent.

```bash
make prepare
make fetch
make patch
make
make install
```

The source branch defaults to the running kernel major/minor version, for
example `rpi-6.13.y`. Override it when necessary:

```bash
make KERNEL_BRANCH=rpi-6.13.y all
```

Installation does not unload the active driver and does not reboot.
