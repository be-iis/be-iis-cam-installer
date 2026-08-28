# Dual camera examples

These are small **example implementations**, not reference code. They show
one practical way to run both BE-IIS GMSL2 camera links at once. Product
implementations remain responsible for their own validation, fault handling,
performance qualification and safety requirements.

## For people

First initialise both camera links:

```bash
make unoverlay
make cameras-a-b
make a-b
```

### HDMI preview on the Pi

Shows camera 0 on the left and camera 1 on the right on a directly connected
800x480 HDMI display:

```bash
python3 examples/dual-hdmi-preview/dual_preview.py
```

Stop with `Ctrl+C`.

### Preview on a PC

The companion example sends the same combined image to a PC over the local
network as MJPEG/RTP. Run it on the Pi with the PC's IP address:

```bash
python3 examples/dual-pc-preview/dual_stream_to_pc.py 192.168.178.116
```

Then run the receiver command shown in
[`../dual-pc-preview/README.md`](../dual-pc-preview/README.md) on the PC.

## Dependencies

```bash
sudo apt install python3-gi python3-gst-1.0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
```

## Why this structure?

Both cameras must be captured by two independent `rpicam-vid` processes.
For this dual-camera setup, two `libcamerasrc` elements in one process led
to a PiSP camera-frontend timeout.

The camera process writes I420 frames at 1024x576 pixels. One frame is exactly
884736 bytes. The Python reader therefore collects one complete frame before
placing it in a short per-camera queue.

The important detail is that the reader threads **do not call GStreamer**.
Only the GLib main thread injects frames into the two `appsrc` elements.
This was required here because pushing both live camera streams directly from
two Python threads produced horizontal image offsets in the combined live
image. Serialised injection removed the offsets.

Old frames may be discarded when a queue is full. This keeps latency bounded;
a discarded item is always a whole frame, never part of an image.

## For AI and developers

- Keep two separate `rpicam-vid` processes; do not replace them with two
  `libcamerasrc` elements without validating the PiSP dual-camera case.
- Capture format: I420, 1024x576, 30 fps, 884736 bytes/frame.
- Preserve full-frame boundaries in the Python reader.
- Use `rawvideoparse format=i420 width=1024 height=576 framerate=30/1`.
  It reconstructs and timestamps complete raw video frames before conversion.
- Feed `appsrc` from one serial GStreamer/GLib context. Reader threads may
  read camera pipes and enqueue immutable frame data only.
- The compositor places camera 0 left and camera 1 right. Do not assume the
  numeric index maps universally to GMSL links; on this setup index 0 is
  `imx708@53` (Link B) and index 1 is `imx708@52` (Link A).
- HDMI uses the Raspberry Pi VC4 DRM driver and an 800x480 output. Camera
  images are scaled to 400x225 and vertically centred.
