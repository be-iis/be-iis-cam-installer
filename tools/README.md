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


## GMSL2 3 Gbit/s / 6 Gbit/s mode switch

`set-gmsl-rate.py` switches the MAX96717 transmitter and matching MAX96716A
receiver rate explicitly. It does not rely on strap defaults.

For both links:

```bash
make rate-3g
make rate-6g
```

For one physical link only:

```bash
make rate-3g RATE_LINK=A
make rate-3g RATE_LINK=B
```

The switch sequence selects the still-working link, changes MAX96717
`TX_RATE[3:2]`, changes the corresponding MAX96716A receive-rate field,
forces a one-shot link reset, waits for lock, verifies both rate fields and
reports the read-to-clear decode counter after a short dwell.

The normal `imx708-revb` profile remains a 6 Gbit/s profile. These targets are
intended for cable/link-margin experiments after normal bring-up.


## MAX96717 TX-amplitude soak test

`gmsl-tx-amp-test.py` changes only the selected MAX96717 forward-link TX
amplitude through `RLMS95 (0x1495)`. The current GMSL2 rate and MAX96716A
receiver EQ/adaptation are left unchanged.

The tool preserves `ADCSarMethod` (bit 6), enables the manual TX-amplitude
override (bit 7), writes the requested `TxAmplMan[5:0]` code, clears the
selected MAX96716A read-to-clear decode counter, and watches the link for the
requested dwell time. The first decode-error event gets an immediate snapshot.
The exact original serializer register byte is restored afterwards unless
`APPLY=1` is used.

Example, Link A with amplitude code 45 for 60 seconds:

```bash
make tx-amp-test LINK=A TX_AMP_CODE=0x2d TX_AMP_DWELL=60
```

Useful comparison points:

```bash
make tx-amp-test LINK=A TX_AMP_CODE=0x29 TX_AMP_DWELL=60
make tx-amp-test LINK=A TX_AMP_CODE=0x2d TX_AMP_DWELL=60
make tx-amp-test LINK=A TX_AMP_CODE=0x31 TX_AMP_DWELL=60
make tx-amp-test LINK=A TX_AMP_CODE=0x35 TX_AMP_DWELL=60
```

Results are stored below `captures/tx-amp-test/`.


## MAX96716A 6 Gbit/s long-channel errata test

`gmsl-long-channel-test.py` applies the Analog Devices MAX96716A/MAX96716F
errata workaround for 6 Gbit/s channels with high insertion loss:

- `RLMS1F = 0x8c` (initial gain)
- `RLMS23 = 0x58` (initial boost)
- one `RESET_ONESHOT` on the selected link

The tool first verifies that the selected link is currently configured for
6 Gbit/s. It then applies the two full-byte writes exactly as documented,
performs one reset, clears the selected read-to-clear decode counter, and soaks
the link for the requested dwell time. The first decode-error event gets an
immediate snapshot.

Example:

```bash
make long-channel-test LINK=A LONG_CHANNEL_DWELL=60
```

The original `RLMS1F` and `RLMS23` bytes are restored afterwards unless
`APPLY=1` is supplied.
