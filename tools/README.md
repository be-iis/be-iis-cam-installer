# Tools

## ADI kernel

- `adi/clone-adi-linux.sh`: clone the supported ADI GMSL kernel branch.
- `adi/build-install-kernel.sh`: configure, patch, build and install the
  complete Raspberry Pi 5 ADI GMSL kernel.
- `adi/patches/0001-media-imx708-handle-reset-gpio-errors.patch`: stop IMX708
  probe cleanly when its reset GPIO provider returns an error.

## MAX96716A CFG1 on older hardware

`set-cfg1-ratio.sh` programs channel B of the TPL0102-100 digital
potentiometer and stores the value in EEPROM.
This utility is for older hardware with a TPL0102 at `0x51`. The Rev. B
2CAM board has no DigiPot. Its profile sets 6 Gbit/s, coax and tunnel mode
directly in MAX96716A registers during link initialization; do not run this
utility for Rev. B.

Example:

```bash
./set-cfg1-ratio.sh --ratio 67.95 --i2c-device 11
```


## MAX96716A manual EQ / cable-margin sweep

`gmsl-eq-sweep.py` is a lab diagnostic for one GMSL2 link at a time. It:

- disables `AdaptEn` and periodic AEQ on the selected receiver,
- sweeps the documented `BSTInit` field around a known-good starting value,
- performs a one-shot link reset for every value so `BSTInit` is applied,
- clears and polls the read-to-clear decode-error counter,
- stores an RLMS snapshot immediately on the first decode-error hit,
- finds the contiguous error-free window and verifies its midpoint again.

A camera stream is not required for the GMSL decode counter. If one is running,
the one-shot reset at each setting can interrupt it. Do **not** run
`dual_preview.py --gmsl` at the same time because both tools consume the same
read-to-clear counters.

Example:

```bash
git switch test/manual-eq-sweep
make eq-sweep LINK=A EQ_START=0x18 EQ_DWELL=5
```

The default restores the exact original EQ registers after the test. To leave
the selected midpoint active with AEQ disabled:

```bash
make eq-sweep LINK=A EQ_START=0x18 EQ_DWELL=10 APPLY=1
```

Results and JSON snapshots are written below
`captures/eq-sweep/<timestamp>-link-X/`.

`BSTInit` is an initial receiver-boost value, not a readable live AEQ
coefficient. This tool therefore characterizes a reproducible manual starting
point rather than attempting to freeze an undocumented internal adaptive
coefficient.
