#!/usr/bin/env python3
"""Send the dual-camera side-by-side preview to a PC as MJPEG/RTP."""

import argparse
import pathlib
import signal
import sys

import gi

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "dual-hdmi-preview"))
from dual_preview import (  # noqa: E402
    PREVIEW_HEIGHT,
    PREVIEW_WIDTH,
    branch,
    start_captures,
)

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send the dual BE-IIS camera preview to a PC via MJPEG/RTP."
    )
    parser.add_argument("host", help="IPv4 address of the receiving PC")
    parser.add_argument("--port", type=int, default=5000)
    args = parser.parse_args()

    Gst.init(None)
    output_width = PREVIEW_WIDTH * 2
    description = " ".join((
        branch("camera0", "sink_0"),
        branch("camera1", "sink_1"),
        "compositor name=compositor "
        "sink_0::xpos=0 sink_0::ypos=0 "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos=0 ! "
        f"video/x-raw,width={output_width},height={PREVIEW_HEIGHT} ! "
        "videoconvert ! jpegenc quality=85 ! rtpjpegpay ! "
        f"udpsink host={args.host} port={args.port} sync=false",
    ))
    pipeline = Gst.parse_launch(description)
    loop = GLib.MainLoop()
    bus = pipeline.get_bus()
    bus.add_signal_watch()

    def on_message(_bus, message):
        if message.type == Gst.MessageType.ERROR:
            error, detail = message.parse_error()
            print(f"Stream error: {error.message}\n{detail or ''}", file=sys.stderr)
            loop.quit()

    bus.connect("message", on_message)
    signal.signal(signal.SIGINT, lambda *_: loop.quit())
    pipeline.set_state(Gst.State.PLAYING)
    captures = start_captures(pipeline)
    try:
        loop.run()
    finally:
        pipeline.set_state(Gst.State.NULL)
        for process in captures:
            process.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
