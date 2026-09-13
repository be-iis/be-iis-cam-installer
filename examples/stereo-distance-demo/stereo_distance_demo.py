#!/usr/bin/env python3
"""Headless stereo distance demo for the BE-IIS dual GMSL2 camera platform."""
import argparse
import queue
import signal
import subprocess
import sys
import threading

import cv2
import gi
import numpy as np

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst

WIDTH, HEIGHT, FPS = 1024, 576, 30
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
DISPLAY_WIDTH, DISPLAY_HEIGHT = 800, 480


def capture(camera):
    return subprocess.Popen(
        ["rpicam-vid", "--camera", str(camera), "--nopreview", "--codec", "yuv420",
         "--width", str(WIDTH), "--height", str(HEIGHT), "--framerate", str(FPS),
         "--timeout", "0", "--output", "-"],
        stdout=subprocess.PIPE,
    )


def feed(process, frames):
    while True:
        data = bytearray()
        while len(data) < FRAME_SIZE:
            chunk = process.stdout.read(FRAME_SIZE - len(data))
            if not chunk:
                frames.put(None)
                return
            data.extend(chunk)
        try:
            frames.put_nowait(bytes(data))
        except queue.Full:
            try:
                frames.get_nowait()
            except queue.Empty:
                pass
            frames.put_nowait(bytes(data))


def newest(frames):
    result = None
    while True:
        try:
            result = frames.get_nowait()
        except queue.Empty:
            return result


class StereoDemo:
    def __init__(self, calibration_path, baseline_mm):
        self.calibrated = calibration_path is not None
        if calibration_path:
            data = np.load(calibration_path)
            self.map0x, self.map0y = data["map0x"], data["map0y"]
            self.map1x, self.map1y = data["map1x"], data["map1y"]
            self.focal_px = float(data["focal_px"])
            self.baseline_m = float(data["baseline_m"])
        else:
            # Quick demonstration only: assumes cameras are parallel and uses
            # IMX708's approximate 66 degree horizontal field of view.
            grid_x, grid_y = np.meshgrid(
                np.arange(WIDTH, dtype=np.float32), np.arange(HEIGHT, dtype=np.float32))
            self.map0x = self.map1x = grid_x
            self.map0y = self.map1y = grid_y
            self.focal_px = WIDTH / (2.0 * np.tan(np.deg2rad(33.0)))
            self.baseline_m = baseline_mm / 1000.0
        self.matcher = cv2.StereoSGBM_create(
            minDisparity=0, numDisparities=96, blockSize=7,
            P1=8 * 3 * 7 * 7, P2=32 * 3 * 7 * 7,
            disp12MaxDiff=1, uniquenessRatio=8, speckleWindowSize=80,
            speckleRange=2, mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY)
        self.distance_m = None
        self.frame_number = 0

    def distance_at_crosshair(self, left, right):
        # Calculate at half resolution; three recalculations per second are enough
        # for a stable, readable exhibition display.
        small0 = cv2.resize(left, (WIDTH // 2, HEIGHT // 2), interpolation=cv2.INTER_AREA)
        small1 = cv2.resize(right, (WIDTH // 2, HEIGHT // 2), interpolation=cv2.INTER_AREA)
        gray0 = cv2.cvtColor(small0, cv2.COLOR_BGR2GRAY)
        gray1 = cv2.cvtColor(small1, cv2.COLOR_BGR2GRAY)
        disparity = self.matcher.compute(gray0, gray1).astype(np.float32) / 16.0
        h, w = disparity.shape
        roi = disparity[h // 2 - 18:h // 2 + 18, w // 2 - 18:w // 2 + 18]
        valid = roi[(roi > 1.0) & np.isfinite(roi)]
        if valid.size < 80:
            return None
        # The half-size image also halves focal length and disparity.
        return (self.focal_px / 2.0) * self.baseline_m / float(np.median(valid))

    @staticmethod
    def draw_crosshair(image):
        h, w = image.shape[:2]
        x, y = w // 2, h // 2
        cv2.drawMarker(image, (x, y), (0, 220, 255), cv2.MARKER_CROSS, 28, 2)

    def render(self, data0, data1):
        raw0 = np.frombuffer(data0, np.uint8).reshape((HEIGHT * 3 // 2, WIDTH))
        raw1 = np.frombuffer(data1, np.uint8).reshape((HEIGHT * 3 // 2, WIDTH))
        image0 = cv2.cvtColor(raw0, cv2.COLOR_YUV2BGR_I420)
        image1 = cv2.cvtColor(raw1, cv2.COLOR_YUV2BGR_I420)
        left = cv2.remap(image0, self.map0x, self.map0y, cv2.INTER_LINEAR)
        right = cv2.remap(image1, self.map1x, self.map1y, cv2.INTER_LINEAR)

        self.frame_number += 1
        if self.frame_number % 10 == 0:
            self.distance_m = self.distance_at_crosshair(left, right)

        left = cv2.resize(left, (WIDTH // 2, HEIGHT // 2))
        right = cv2.resize(right, (WIDTH // 2, HEIGHT // 2))
        self.draw_crosshair(left)
        self.draw_crosshair(right)
        canvas = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
        canvas[:HEIGHT // 2, :WIDTH // 2] = left
        canvas[:HEIGHT // 2, WIDTH // 2:] = right
        cv2.line(canvas, (WIDTH // 2, 0), (WIDTH // 2, HEIGHT // 2), (255, 255, 255), 1)
        cv2.putText(canvas, "BE-IIS  |  GMSL2 Stereo Vision", (30, 345),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (220, 220, 220), 2, cv2.LINE_AA)
        prefix = "" if self.calibrated else "~ "
        label = "Entfernung: --" if self.distance_m is None else f"{prefix}Entfernung: {self.distance_m:.2f} m"
        cv2.putText(canvas, label, (30, 455), cv2.FONT_HERSHEY_DUPLEX, 2.0,
                    (0, 220, 255), 3, cv2.LINE_AA)
        cv2.putText(canvas, "Objekt auf das Kreuz halten", (30, 515),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.75, (220, 220, 220), 2, cv2.LINE_AA)
        return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calibration", default=None,
                        help="stereo_calibration.npz from calibrate.py")
    parser.add_argument("--baseline-mm", type=float, default=120.0,
                        help="camera-centre spacing for uncalibrated quick mode")
    args = parser.parse_args()
    try:
        demo = StereoDemo(args.calibration, args.baseline_mm)
    except (OSError, KeyError) as error:
        sys.exit(f"Calibration file cannot be loaded: {error}")

    Gst.init(None)
    pipeline = Gst.parse_launch(
        "appsrc name=display is-live=true block=true do-timestamp=true format=time "
        "caps=video/x-raw,format=BGR,width=1024,height=576,framerate=30/1 "
        "! queue max-size-buffers=2 leaky=downstream ! videoconvert ! videoscale "
        "! video/x-raw,width=800,height=480,pixel-aspect-ratio=1/1 "
        "! kmssink")
    appsrc = pipeline.get_by_name("display")
    loop = GLib.MainLoop()
    captures = [capture(0), capture(1)]
    queues = [queue.Queue(maxsize=2), queue.Queue(maxsize=2)]
    for process, frames in zip(captures, queues):
        threading.Thread(target=feed, args=(process, frames), daemon=True).start()

    def drain():
        data0, data1 = newest(queues[0]), newest(queues[1])
        if data0 is None or data1 is None:
            return True
        image = demo.render(data0, data1)
        buffer = Gst.Buffer.new_allocate(None, image.nbytes, None)
        buffer.fill(0, image.tobytes())
        return appsrc.emit("push-buffer", buffer) == Gst.FlowReturn.OK

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message::error", lambda _bus, message: (
        print(f"Display error: {message.parse_error()[0].message}", file=sys.stderr), loop.quit()))
    GLib.timeout_add(1, drain)
    signal.signal(signal.SIGINT, lambda *_: loop.quit())
    pipeline.set_state(Gst.State.PLAYING)
    try:
        loop.run()
    finally:
        pipeline.set_state(Gst.State.NULL)
        for process in captures:
            process.terminate()
        for process in captures:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
