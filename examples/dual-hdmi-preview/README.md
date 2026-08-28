# Dual HDMI preview — example implementation

This is deliberately a small **example implementation**, not reference code.
It demonstrates the application boundary required for a dual-camera product:
one process owns both libcamera sources, composes them, and presents one HDMI
framebuffer. Integrators remain responsible for validating their camera,
display, timing, memory-bandwidth, error-recovery and safety requirements.

The program is intended for a Raspberry Pi 5 with two cameras exposed by
libcamera as camera indices `0` and `1`. It renders both streams side by side
on an 800x480 DRM/KMS display. Change the constants at the top of
`dual_preview.py` for another display mode.

## Dependencies

```bash
sudo apt install python3-gi python3-gst-1.0 \
  gstreamer1.0-tools gstreamer1.0-libcamera \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad
```

## Run

```bash
python3 examples/dual-hdmi-preview/dual_preview.py
```

Use `Ctrl+C` to return to the console.
