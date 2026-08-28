#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only.

Not reference code. Product implementations must provide their own
validation, fault handling and performance qualification.
"""

import signal
import subprocess
import sys
import threading

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst

DISPLAY_WIDTH = 800
DISPLAY_HEIGHT = 480
PREVIEW_WIDTH = 400
PREVIEW_HEIGHT = 225
PREVIEW_Y = (DISPLAY_HEIGHT - PREVIEW_HEIGHT) // 2
CAPTURE_WIDTH = 960
CAPTURE_HEIGHT = 540
FRAMERATE = 30

# rpicam-vid's YUV420 buffers are stride-aligned by libcamera.
Y_STRIDE = 1024
UV_STRIDE = 512
Y_SIZE = Y_STRIDE * CAPTURE_HEIGHT
U_OFFSET = Y_SIZE
V_OFFSET = U_OFFSET + UV_STRIDE * (CAPTURE_HEIGHT // 2)
FRAME_SIZE = V_OFFSET + UV_STRIDE * (CAPTURE_HEIGHT // 2)


def capture(camera: int) -> subprocess.Popen:
    return subprocess.Popen(
        [
            "rpicam-vid", "--camera", str(camera), "--nopreview",
            "--codec", "yuv420", "--width", str(CAPTURE_WIDTH),
            "--height", str(CAPTURE_HEIGHT), "--framerate", str(FRAMERATE),
            "--timeout", "0", "--output", "-",
        ],
        stdout=subprocess.PIPE,
    )


def branch(name: str, pad: str) -> str:
    return (
        f"appsrc name={name} is-live=true block=true do-timestamp=true "
        "format=time ! rawvideoparse "
        f"format=i420 width={CAPTURE_WIDTH} height={CAPTURE_HEIGHT} "
        f'plane-strides="<{Y_STRIDE},{UV_STRIDE},{UV_STRIDE}>" '
        f'plane-offsets="<0,{U_OFFSET},{V_OFFSET}>" framerate={FRAMERATE}/1 ! '
        "videoconvert ! videoscale ! "
        f"video/x-raw,width={PREVIEW_WIDTH},height={PREVIEW_HEIGHT} ! "
        f"queue max-size-buffers=2 leaky=downstream ! compositor.{pad}"
    )


def feed(process: subprocess.Popen, appsrc: Gst.Element) -> None:
    assert process.stdout is not None
    while True:
        frame = bytearray()
        while len(frame) < FRAME_SIZE:
            chunk = process.stdout.read(FRAME_SIZE - len(frame))
            if not chunk:
                appsrc.emit("end-of-stream")
                return
            frame.extend(chunk)
        buffer = Gst.Buffer.new_allocate(None, FRAME_SIZE, None)
        buffer.fill(0, frame)
        if appsrc.emit("push-buffer", buffer) != Gst.FlowReturn.OK:
            return


def main() -> int:
    Gst.init(None)
    description = " ".join((
        branch("camera0", "sink_0"),
        branch("camera1", "sink_1"),
        "compositor name=compositor "
        f"sink_0::xpos=0 sink_0::ypos={PREVIEW_Y} "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos={PREVIEW_Y} ! "
        f"video/x-raw,width={DISPLAY_WIDTH},height={DISPLAY_HEIGHT} ! "
        "videoconvert ! kmssink sync=false",
    ))
    pipeline = Gst.parse_launch(description)
    loop = GLib.MainLoop()
    bus = pipeline.get_bus()
    bus.add_signal_watch()

    def on_message(_bus, message):
        if message.type == Gst.MessageType.ERROR:
            error, detail = message.parse_error()
            print(f"Preview error: {error.message}\n{detail or ''}", file=sys.stderr)
            loop.quit()
        elif message.type == Gst.MessageType.EOS:
            loop.quit()

    bus.connect("message", on_message)
    signal.signal(signal.SIGINT, lambda *_: loop.quit())
    pipeline.set_state(Gst.State.PLAYING)
    captures = [capture(0), capture(1)]
    threads = [
        threading.Thread(target=feed, args=(captures[0], pipeline.get_by_name("camera0")), daemon=True),
        threading.Thread(target=feed, args=(captures[1], pipeline.get_by_name("camera1")), daemon=True),
    ]
    for thread in threads:
        thread.start()
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
