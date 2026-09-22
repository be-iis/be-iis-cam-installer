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
in the status panel below the corresponding image, add `--ina`:

```bash
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina
```

Camera 0 is physically Link B (INA226 `0x45`); camera 1 is Link A
(INA226 `0x41`). The readout uses the fitted 10mOhm shunts.

### Live status below each video

Status panels are always visible, including without `--ina`, and refresh once
per second. They use separate black video sources so status can update even
when a camera stops delivering frames.

| Field | Meaning |
| --- | --- |
| Link / state | Physical link; RUN, WAIT for first frame, STALL, EOF, or process EXIT code |
| Focus | Configured autofocus/manual position; not a measured lens position |
| Out | Requested output resolution used by the raw frame reader |
| RX fps | Complete frames received from the camera process during the last update interval, followed by requested fps |
| Sensor | Actual selected sensor format parsed from the camera startup log; pending if not reported |
| Frames | Complete frames received since startup |
| Preview skip | Complete frames discarded in the Python preview queue to keep latency bounded |
| RX gaps / Last | Pauses between received frames longer than max(250 ms, three requested frame periods); last such pause in ms |
| Age | Time since the most recent complete frame; STALL after max(1 s, three requested frame periods) |
| Log errors / Warnings | Camera log lines containing ERROR/FATAL or WARN/WARNING; errors also include incomplete frames and failed GStreamer buffer submission |
| INA | Voltage/current with `--ina`, or read error / off |
| Last message | Tail of the most recent warning/error; full camera logs remain on stderr with link prefixes |

The fields above are **host-side observations**. Optional hardware monitoring
is described below. RX fps is
neither a sensor timestamp measurement nor the HDMI display rate. RX gaps can
also result from host scheduling or backpressure. Preview skip does not count
frames discarded later inside GStreamer. Small image corruption without a log
message or timing change is not detected; zero errors does not prove a clean
physical link. Initial camera startup delay is excluded from RX gaps.

### Optional hardware diagnostics

```bash
sudo python3 examples/dual-hdmi-preview/dual_preview.py --ina --gmsl
```

The MAX96716A is polled in the background. `--gmsl-bus` defaults to 11;
`--gmsl-address` defaults to `0x28`. One cooperating monitor is allowed per device.
Do not run other register readers concurrently: these reads consume flags.

The [MAX96716A data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/max96716a.pdf)
documents tunnel status at `0x0442`/`0x0482` (pages 219/239) and decoding
counters at `0x0022`/`0x0023` (page 124). CRC, corrected/uncorrectable ECC and
sync-loss flags clear on read. The display accumulates **flagged polling
intervals**, not individual corrupt packets. `DEC` sums consumed decoding counts;
resets, saturation and other readers can cause undercounting.

Initial reads establish a baseline; pre-existing errors are excluded. Counters
restart with the application. I2C failures show unavailable/stale, not zero.
Routing is checked against this repository's dual-tunnel setup before consuming
status. Other mappings are rejected. No link configuration registers are written
and no serializer switching is performed.

Tunnel CRC covers the transported CSI data, not a universal GMSL packet CRC
counter. A hit does not uniquely identify a cable fault. Hardware measurements
still need validation on the Pi. Software log errors remain a separate count.

INA polling runs in a background thread with bounded subprocess timeouts, so
I2C reads do not block the GLib frame delivery loop. A fatal GStreamer pipeline
error is still printed to the terminal and ends the preview.

### Capture resolution and sensor mode

`--width`, `--height` and `--framerate` set the capture output for both cameras.
Defaults remain 1024x576 at 30 fps. `--mode` separately requests the sensor mode
in `WIDTH:HEIGHT[:BITS[:P|U]]` format; when omitted, rpicam selects it automatically.
Check the rpicam startup log for the actual selected sensor mode.

```bash
# Full HD output, 2304x1296 sensor mode, 30 fps
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina \
  --width 1920 --height 1080 --framerate 30 --mode 2304:1296:10

# 2304x1296 output and sensor mode, 30 fps
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina \
  --width 2304 --height 1296 --framerate 30 --mode 2304:1296:10

# Full IMX708 resolution, initially request 10 fps
sudo -E python3 examples/dual-hdmi-preview/dual_preview.py --ina \
  --width 4608 --height 2592 --framerate 10 --mode 4608:2592:10
```

These are hardware test configurations, not guaranteed dual-camera throughput.
Higher resolutions increase CPU and memory bandwidth usage. The HDMI display
remains 800x480 with two 400x225 previews; larger capture frames are downscaled.
Focus options can be combined with any of these commands.

For this raw I420 pipe example, output width must be a positive multiple of 32,
height must be positive and even, and frame rate must be a positive integer.
These restrictions keep frame boundaries and plane alignment predictable.
Frame byte counts and GStreamer parser settings follow the requested output
size. If rpicam adjusts the output dimensions, use dimensions it supports.

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

By default, the camera process writes I420 frames at 1024x576 pixels (884736
bytes per frame). With custom dimensions, each frame is width * height * 3 / 2
bytes. The Python reader therefore collects one complete frame before
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
- Capture format: I420; default 1024x576, 30 fps, 884736 bytes/frame.
  The CLI configures dimensions, frame rate and frame size before threads start.
- Preserve full-frame boundaries in the Python reader.
- Use `rawvideoparse format=i420` with the configured width, height and frame rate.
  It reconstructs and timestamps complete raw video frames before conversion.
- Feed `appsrc` from one serial GStreamer/GLib context. Reader threads may
  read camera pipes and enqueue immutable frame data only.
- The compositor places camera 0 left and camera 1 right. Do not assume the
  numeric index maps universally to GMSL links; on this setup index 0 is
  `imx708@53` (Link B) and index 1 is `imx708@52` (Link A).
- HDMI uses the Raspberry Pi VC4 DRM driver and an 800x480 output. Camera
  images are scaled to 400x225 at y=40; 400x200 status panels start at y=265.
- Monitoring counters are protected by a lock. Camera log readers and INA
  polling must not call GStreamer; labels are updated by the GLib thread.

Hardware-independent monitoring checks:

```bash
python3 -m unittest discover -s examples/dual-hdmi-preview/tests -v
```

These checks do not replace a live Raspberry Pi/GStreamer display test.
