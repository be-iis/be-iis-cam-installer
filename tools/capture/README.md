# Capture tools

`capture-image.sh` and `capture-video.sh` provide stable command-line options
over `rpicam-still` and `rpicam-vid`.

```bash
./capture-image.sh --megapixels 3 --output image.jpg
./capture-image.sh --megapixels 3 --raw --output image.jpg
./capture-video.sh --megapixels 3 --duration 10 --output video.mjpeg
```

MJPEG is the default because Raspberry Pi 5 does not provide a hardware H.264
encoder. H.264 remains selectable with `--codec h264` when a suitable encoder
is available.

Profiles:

| Value | Resolution | IMX708 mode |
|---:|---:|---|
| 1 | 1536 × 864 | 2×2 cropped/binned |
| 3 | 2304 × 1296 | 2×2 binned |
| 12 | 4608 × 2592 | full resolution |
