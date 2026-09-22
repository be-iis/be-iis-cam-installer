# Dual camera examples

These are small **example implementations**, not reference code. They show
one practical way to run both BE-IIS GMSL2 camera links at once. Product
implementations remain responsible for their own validation, fault handling,
performance qualification and safety requirements.

## For people

First prepare both camera links and video pipelines:

```bash
make unoverlay
make prepare-a-b
make pipeline-a-b
```

### HDMI preview on the Pi

Shows camera 0 on the left and camera 1 on the right on a directly connected
800x480 HDMI display:

```bash
make video-dual
```

Equivalent direct command:

```bash
python3 examples/dual-hdmi-preview/dual_preview.py
```

Stop with `Ctrl+C`.

Both camera images are rotated 180°. To show the live camera-supply readout
at the lower edge of the corresponding image, add `--ina`:

```bash
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina
```

Camera 0 is physically Link B (INA226 `0x45`); camera 1 is Link A
(INA226 `0x41`). The readout uses the fitted 10mOhm shunts.

### Optional manual focus

Use `--focus-a` and `--focus-b` to control each physical link independently:

```bash
# Link A: continuous autofocus; Link B: fixed focus near 20 cm
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina --focus-a auto --focus-b 5

# Link A: fixed far focus; Link B: continuous autofocus
python3 examples/dual-hdmi-preview/dual_preview.py --focus-a 0 --focus-b auto
```

`auto` explicitly selects continuous autofocus. A number selects manual focus
in dioptres. Link A is camera 1 (right); Link B is camera 0 (left).
Each per-link option overrides `--lens-position` for that link. An omitted
per-link option uses `--lens-position` if supplied, otherwise the camera default.

Use `--lens-position` to set a fixed focus position for **both cameras**:

```bash
# Far focus (infinity)
python3 examples/dual-hdmi-preview/dual_preview.py --lens-position 0

# Near focus (approximately 20 cm), with supply readout
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina --lens-position 5
```

The option selects manual focus and passes the position to both `rpicam-vid`
processes. Values are in dioptres (1 / distance in metres); distances are
approximate and the supported range depends on the camera. Requires a camera
with a controllable focus lens. Negative and non-finite values are rejected.
Stop with `Ctrl+C` and restart with another value to change the fixed position.

Omit all focus options to preserve the existing camera default/autofocus
behaviour. Existing service commands need no changes. If a preview service is
running, stop it before starting this example manually to free the cameras.

### Stereo distance measurement

The headless stereo demonstration overlays the distance at a fixed crosshair.
It needs a one-time chessboard calibration and works directly via DRM/KMS:

[`../stereo-distance-demo/README.md`](../stereo-distance-demo/README.md)

### Preview on a PC

The companion example sends the same combined image to a PC over the local
network as MJPEG/RTP. Run it on the Pi with the PC's IP address:

```bash
python3 examples/dual-pc-preview/dual_stream_to_pc.py 192.168.178.116
```

Then run the receiver command shown in
[`../dual-pc-preview/README.md`](../dual-pc-preview/README.md) on the PC.

## Dependencies

The normal `./install.sh` installs these dependencies. For a manual install:

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
