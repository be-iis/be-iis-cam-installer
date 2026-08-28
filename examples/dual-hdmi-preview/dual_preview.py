#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only."""
import queue
import signal
import subprocess
import sys
import threading

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst

DISPLAY_WIDTH, DISPLAY_HEIGHT = 800, 480
PREVIEW_WIDTH, PREVIEW_HEIGHT = 400, 225
PREVIEW_Y = (DISPLAY_HEIGHT - PREVIEW_HEIGHT) // 2
CAPTURE_WIDTH, CAPTURE_HEIGHT, FRAMERATE = 1024, 576, 30
FRAME_SIZE = CAPTURE_WIDTH * CAPTURE_HEIGHT * 3 // 2


def capture(camera):
    return subprocess.Popen(
        [
            "rpicam-vid", "--camera", str(camera), "--nopreview",
            "--codec", "yuv420", "--width", str(CAPTURE_WIDTH),
            "--height", str(CAPTURE_HEIGHT), "--framerate", str(FRAMERATE),
            "--timeout", "0", "--output", "-",
        ],
        stdout=subprocess.PIPE,
    )


def branch(name, pad):
    return (
        f"appsrc name={name} is-live=true block=true do-timestamp=true "
        f"format=time "
        f"! rawvideoparse format=i420 width={CAPTURE_WIDTH} "
        f"height={CAPTURE_HEIGHT} framerate={FRAMERATE}/1 "
        f"! videoconvert ! videoscale "
        f"! video/x-raw,width={PREVIEW_WIDTH},height={PREVIEW_HEIGHT},"
        f"pixel-aspect-ratio=1/1 "
        f"! queue max-size-buffers=2 leaky=downstream ! compositor.{pad}"
    )


def feed(process, frames):
    """Read complete camera frames; never call GStreamer from this thread."""
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


def latest_frame(frames):
    data = None
    while True:
        try:
            data = frames.get_nowait()
        except queue.Empty:
            return data


def push_frame(appsrc, data):
    buffer = Gst.Buffer.new_allocate(None, FRAME_SIZE, None)
    buffer.fill(0, data)
    return appsrc.emit("push-buffer", buffer) == Gst.FlowReturn.OK


def start_captures(pipeline):
    """Start both readers and inject frames from the GLib main thread."""
    captures = [capture(0), capture(1)]
    frame_queues = [queue.Queue(maxsize=2), queue.Queue(maxsize=2)]
    sources = [
        (pipeline.get_by_name("camera0"), frame_queues[0]),
        (pipeline.get_by_name("camera1"), frame_queues[1]),
    ]
    for process, frames in zip(captures, frame_queues):
        threading.Thread(target=feed, args=(process, frames), daemon=True).start()

    def drain_frames():
        for appsrc, frames in sources:
            data = latest_frame(frames)
            if data is not None and not push_frame(appsrc, data):
                return False
        return True

    GLib.timeout_add(1, drain_frames)
    return captures


def main():
    Gst.init(None)
    desc = " ".join((
        branch("camera0", "sink_0"),
        branch("camera1", "sink_1"),
        "compositor name=compositor "
        f"sink_0::xpos=0 sink_0::ypos={PREVIEW_Y} "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos={PREVIEW_Y} "
        f"! video/x-raw,width={DISPLAY_WIDTH},height={DISPLAY_HEIGHT},"
        "pixel-aspect-ratio=1/1 "
        "! videoconvert ! kmssink driver-name=vc4-drm",
    ))
    pipeline = Gst.parse_launch(desc)
    loop = GLib.MainLoop()
    bus = pipeline.get_bus()
    bus.add_signal_watch()

    def on_message(_bus, message):
        if message.type == Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            print(f"Preview error: {error.message}\n{debug or ''}", file=sys.stderr)
            loop.quit()
        elif message.type == Gst.MessageType.EOS:
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
        for process in captures:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
