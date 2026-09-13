# Stereo distance demonstration

A headless HDMI demonstration for two BE-IIS GMSL2 camera links on a Raspberry Pi 5.
It shows rectified live images and measures the distance at the fixed yellow
crosshair. No X server, mouse or GUI is used.

The display deliberately asks visitors to place a hand, a honey jar or another
textured object on the crosshair. That makes the depth measurement immediate
and avoids pretending that this short exhibition demo is a production-grade
object-recognition system.

## Install dependencies

Start from the normal dual-camera bring-up:

```bash
cd ~/be-iis-cam-installer
make unoverlay
make cameras-a-b
make a-b
sudo apt install python3-opencv python3-gi python3-gst-1.0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
```

## 1. Mount the cameras

Mount both cameras rigidly, side by side and horizontally aligned. A baseline
of roughly 100 to 200 mm is practical for a stand demonstration at distances
of about 0.4 to 3 m. Do not change the camera spacing, angle, focus or
resolution after calibration.

## 2. Calibrate once

Print or buy a flat chessboard with known square size. The defaults expect
**9 x 6 inner corners** and **25 mm squares**. Capture 18 different positions;
the board must be visible in both camera images.

```bash
cd ~/be-iis-cam-installer/examples/stereo-distance-demo
python3 calibrate.py
```

This produces `stereo_calibration.npz` in the current directory. A stereo RMS
below roughly 1 pixel is a good result. Calibration is intentionally terminal
driven; press Enter for every capture.

For another chessboard, specify the real values, for example:

```bash
python3 calibrate.py --corners 7x5 --square-mm 30
```

## 3. Run the HDMI demo

```bash
cd ~/be-iis-cam-installer/examples/stereo-distance-demo
python3 stereo_distance_demo.py
```

The program uses the VC4 DRM/KMS output directly and produces an 800 x 480
screen. Stop it with `Ctrl+C`.

## Notes

- Camera indices follow the existing dual-camera example: camera 0 is Link B
  and camera 1 is Link A. Calibrate and run the demo with exactly this order.
- The cameras need enough overlapping field of view. Use the same lens setting
  for both modules.
- Smooth, reflective, transparent or plain white objects provide too little
  texture for stereo matching. A honey jar label, hand, face or printed card
  works well.
- The demo calculates the median depth in a small patch around the crosshair
  about three times per second. This favours a stable display over maximum
  frame rate.
