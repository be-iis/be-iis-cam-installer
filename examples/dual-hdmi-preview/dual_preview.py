#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only.

Not reference code. Product implementations must provide their own
validation, fault handling and performance qualification.
"""

import signal
import subprocess
import sys

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

# rpicam-vid writes 960 visible pixels into 1024-byte Y rows.
Y_STRIDE = 1024
UV_STRIDE = 512
Y_SIZE = Y_STRIDE * CAPTURE_HEIGHT
U_OFFSET = Y_SIZE
V_OFFSET = U_OFFSET + UV_STRIDE * (CAPTURE_HEIGHT // 2)


def capture(camera: int) -> subprocess.Popen:
    return subprocess.Popen(
        [
            "rpicam-vid",
            "--camera", str(camera),
            "--nopreview",
            "--codec", "yuv420",
            "--width", str(CAPTURE_WIDTH),
            "--height", str(CAPTURE_HEIGHT),
            "--framerate", str(FRAMERATE),
            "--timeout", "0",
            "--output", "-",
        ],
        stdout=subprocess.PIPE,
    )


def source(fd: int, pad: str) -> str:
    return (
        f"fdsrc fd={fd} do-timestamp=true ! "
        f"rawvideoparse format=i420 width={CAPTURE_WIDTH} height={CAPTURE_HEIGHT} "
        f'plane-strides="<{Y_STRIDE},{UV_STRIDE},{UV_STRIDE}>" '
        f'plane-offsets="<0,{U_OFFSET},{V_OFFSET}>" framerate={FRAMERATE}/1 ! '
        f"videoconvert ! videoscale ! "
        f"video/x-raw,width={PREVIEW_WIDTH},height={PREVIEW_HEIGHT} ! "
        f"queue ! compositor.{pad}"
    )


def main() -> int:
    Gst.init(None)
    captures = [capture(0), capture(1)]
    try:
        assert captures[0].stdout and captures[1].stdout
        description = " ".join((
            source(captures[0].stdout.fileno(), "sink_0"),
            source(captures[1].stdout.fileno(), "sink_1"),
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
        try:
            loop.run()
        finally:
            pipeline.set_state(Gst.State.NULL)
    finally:
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
