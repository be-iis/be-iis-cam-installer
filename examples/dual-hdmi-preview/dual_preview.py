#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only.

Not reference code. Product implementations must provide their own
validation, fault handling and performance qualification.
"""

import signal
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

CAMERA_0 = "/base/axi/pcie@1000120000/rp1/i2c@80000/imx708@53"
CAMERA_1 = "/base/axi/pcie@1000120000/rp1/i2c@80000/imx708@52"


def source(camera_name: str, pad: str) -> str:
    return (
        f'libcamerasrc camera-name="{camera_name}" ! '
        f'video/x-raw,format=NV12,width={CAPTURE_WIDTH},height={CAPTURE_HEIGHT},'
        f'framerate={FRAMERATE}/1 ! '
        f'videoconvert ! videoscale ! '
        f'video/x-raw,width={PREVIEW_WIDTH},height={PREVIEW_HEIGHT} ! '
        f'queue ! compositor.{pad}'
    )


def main() -> int:
    Gst.init(None)
    description = " ".join((
        source(CAMERA_0, "sink_0"),
        source(CAMERA_1, "sink_1"),
        "compositor name=compositor "
        f"sink_0::xpos=0 sink_0::ypos={PREVIEW_Y} "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos={PREVIEW_Y} ! "
        f"video/x-raw,width={DISPLAY_WIDTH},height={DISPLAY_HEIGHT} ! "
        "videoconvert ! kmssink sync=false",
    ))
    try:
        pipeline = Gst.parse_launch(description)
    except GLib.Error as error:
        print(f"Unable to construct preview pipeline: {error}", file=sys.stderr)
        return 1

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
