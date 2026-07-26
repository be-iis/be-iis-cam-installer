# Capture tools

`capture-image.sh` and `capture-video.sh` provide stable command-line options
over `rpicam-still` and `rpicam-vid`.

```bash
./capture-image.sh --megapixels 3 --output image.jpg
./capture-image.sh --megapixels 3 --raw --output image.jpg
./capture-video.sh --megapixels 3 --duration 10 --output video.mjpeg
```

Autofocus is enabled by default. Still images use one-shot autofocus during
capture; video uses continuous autofocus. Examples:

```bash
./capture-image.sh --autofocus-range macro --output close-up.jpg
./capture-video.sh --autofocus-speed fast --output video.mjpeg
./capture-image.sh --no-autofocus --output fixed-focus.jpg
./capture-image.sh --autofocus-mode manual --lens-position 2.0 \
    --output manual-focus.jpg
```

The autofocus mode, range, speed and metering window can be selected with
`--autofocus-mode`, `--autofocus-range`, `--autofocus-speed` and
`--autofocus-window`.

HDR is disabled by default and can be enabled for still images or video:

```bash
./capture-image.sh --hdr auto --output hdr.jpg
./capture-video.sh --hdr auto --output hdr-video.mjpeg
./capture-image.sh --hdr single-exp --output onboard-hdr.jpg
```

`--hdr auto` prefers a sensor HDR mode when available and otherwise uses the
Raspberry Pi 5 on-board HDR path. `--hdr single-exp` explicitly selects the
on-board single-exposure HDR path. Use `--hdr off` or `--no-hdr` to disable
HDR.

MJPEG is the default because Raspberry Pi 5 does not provide a hardware H.264
encoder. H.264 remains selectable with `--codec h264` when a suitable encoder
is available.

Profiles:

| Value | Resolution | IMX708 mode |
|---:|---:|---|
| 1 | 1536 × 864 | 2×2 cropped/binned |
| 3 | 2304 × 1296 | 2×2 binned |
| 12 | 4608 × 2592 | full resolution |
