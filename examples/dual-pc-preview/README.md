# Dual camera preview on a PC

This is an **example implementation**, not reference code. It reuses the
tested dual-camera capture path from `../dual-hdmi-preview`, combines both
images on the Pi and sends one MJPEG/RTP stream to a PC.

## On the Pi

Initialise the cameras first, then start the sender with the IP address of
the PC:

```bash
make unoverlay
make cameras-a-b
make a-b
python3 examples/dual-pc-preview/dual_stream_to_pc.py 192.168.178.116
```

Use `--port` to use another UDP port. The default is `5000`.

## On the PC

Install GStreamer once:

```bash
sudo apt install gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good
```

Show the two camera images in one window:

```bash
gst-launch-1.0 -v \
  udpsrc port=5000 caps="application/x-rtp,media=video,encoding-name=JPEG,payload=26,clock-rate=90000" \
  ! rtpjitterbuffer latency=50 \
  ! rtpjpegdepay ! jpegdec ! videoconvert ! autovideosink
```

Camera 0 appears on the left and camera 1 on the right. The receiver keeps
normal output synchronisation enabled; do not add `sync=false` when a
tear-free display is required.
