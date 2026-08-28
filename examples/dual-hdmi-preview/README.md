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

Shows camera 0 on the left and camera 1 on the right on the directly
connected 800x480 HDMI display:

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

## For AI and developers

- Camera acquisition must happen in **two separate `rpicam-vid` processes**.
  Two `libcamerasrc` elements in one process cause a PiSP frontend timeout
  on this dual-camera setup.
- Each camera delivers 960x540 I420 data, but the libcamera buffer has a
  1024-byte Y stride and 512-byte chroma strides. One frame is 829440 bytes.
- The examples use GStreamer `appsrc` to receive complete frames, then
  compose them as camera 0 left and camera 1 right.
- HDMI output is DRM/KMS at 800x480. The camera images are scaled to 400x225
  and vertically centred.
- Do not treat camera index order as universal. This setup maps index 0 to
  `imx708@53` (Link B) and index 1 to `imx708@52` (Link A).
