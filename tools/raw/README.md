# RAW10 conversion

Convert a single tightly packed 2304 × 1296 frame:

```bash
./raw10-to-png.py frame.raw frame.png \
    --width 2304 --height 1296 --bayer BGGR
```

Select a frame from a concatenated capture with `--frame N`.
