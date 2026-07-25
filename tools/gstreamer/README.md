# GStreamer

The helpers use the libcamera GStreamer source so that the Raspberry Pi
camera pipeline handles sensor configuration.

```bash
./preview.sh --megapixels 3 --framerate 30
./record.sh --megapixels 3 --duration 10 --output video.mp4
```

The recorder prefers the Raspberry Pi V4L2 H.264 encoder and falls back to
`x264enc` when available.
