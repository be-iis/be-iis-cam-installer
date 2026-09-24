#!/usr/bin/env python3
"""Send the dual-camera side-by-side preview to a PC as MJPEG/RTP."""

import argparse
import pathlib
import signal
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
from camera_profile import load as load_camera_profile  # noqa: E402

import gi

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "dual-hdmi-preview"))
from dual_preview import PREVIEW_WIDTH, branch, start_captures  # noqa: E402

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst  # noqa: E402

STREAM_HEIGHT = 224  # I420/JPEG 4:2:0 requires an even height.


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send the dual BE-IIS camera preview to a PC via MJPEG/RTP."
    )
    parser.add_argument("host", help="IPv4 address of the receiving PC")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--profile", default="imx708-revb", help="verified camera profile")
    args = parser.parse_args()
    try:
        selected = load_camera_profile(args.profile)
    except (OSError, ValueError, KeyError) as error:
        parser.error(f"invalid camera profile: {error}")

    Gst.init(None)
    output_width = PREVIEW_WIDTH * 2
    description = " ".join((
        branch("camera0", "label0", "sink_0", False, STREAM_HEIGHT),
        branch("camera1", "label1", "sink_1", False, STREAM_HEIGHT),
        "compositor name=compositor "
        "sink_0::xpos=0 sink_0::ypos=0 "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos=0 ! "
        f"video/x-raw,width={output_width},height={STREAM_HEIGHT} ! "
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
    captures = start_captures(pipeline,
                              camera_indices=selected["capture"]["camera_indices"],
                              camera_links=selected["capture"]["links"])
    try:
        loop.run()
    finally:
        pipeline.set_state(Gst.State.NULL)
        for process in captures:
            process.terminate()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
