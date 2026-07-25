# Troubleshooting

## Camera service

```bash
systemctl status be-iis-camera-init.service
journalctl -u be-iis-camera-init.service -b
sudo beiis-camera-init status
```

## Media graph

Only the direct RAW link should be enabled for `/dev/video0` capture:

```bash
media-ctl -d /dev/media3 -p |
    grep -E -- '-> .*\[(ENABLED|IMMUTABLE)'
```

If PiSP links are enabled at the same time, run:

```bash
sudo systemctl restart be-iis-camera-init.service
```

## A zero-byte RAW file

Inspect the V4L2 log and kernel message:

```bash
sudo dmesg -C
v4l2-ctl --verbose --device /dev/video0 \
    --set-fmt-video=width=2304,height=1296,pixelformat=pBAA \
    --stream-mmap=4 --stream-count=1 --stream-to=/tmp/test.raw
sudo dmesg
```

`Broken pipe` normally indicates an invalid or incomplete media pipeline.
`Format mismatch` means the sensor, CSI sink/source, and video node do not
agree on Bayer order, bit depth, or dimensions.

## Corruption in the lower image

Verify that the patched driver is active:

```bash
modinfo -n imx708
v4l2-ctl --device /dev/v4l-subdev2 --get-ctrl horizontal_blanking
```

For 2304 × 1296 with line length `0x2000`, horizontal blanking is 5888.

## Power

```bash
vcgencmd get_throttled
```

Bit `0x10000` records a past undervoltage event; it does not by itself mean
the current 5 V supply is low.
