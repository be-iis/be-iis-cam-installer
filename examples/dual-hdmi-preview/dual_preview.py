#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only."""
import argparse
import math
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
INA226_BUS = 11
INA226_SHUNT_MOHM = 10

# Camera 0 is IMX708@0x53 (Link B); camera 1 is @0x52 (Link A).
CAMERA_INA = (("Link B", "0x45"), ("Link A", "0x41"))


def capture(camera, lens_position=None):
    return subprocess.Popen(
        [
            "rpicam-vid", "--camera", str(camera), "--nopreview",
            "--codec", "yuv420", "--width", str(CAPTURE_WIDTH),
            "--height", str(CAPTURE_HEIGHT), "--framerate", str(FRAMERATE),
            "--timeout", "0", "--output", "-",
        ] + (
            ["--autofocus-mode", "manual", "--lens-position", str(lens_position)]
            if lens_position is not None else []
        ),
        stdout=subprocess.PIPE,
    )


def branch(name, label_name, pad, show_label, preview_height=PREVIEW_HEIGHT):
    label = (
        f"! textoverlay name={label_name} text=\"\" valignment=bottom "
        "halignment=left font-desc=\"Sans 16\" shaded-background=true wait-text=false "
        if show_label else ""
    )
    return (
        f"appsrc name={name} is-live=true block=true do-timestamp=true "
        f"format=time "
        f"! rawvideoparse format=i420 width={CAPTURE_WIDTH} "
        f"height={CAPTURE_HEIGHT} framerate={FRAMERATE}/1 "
        f"! videoconvert ! videoflip method=rotate-180 ! videoscale "
        f"! video/x-raw,width={PREVIEW_WIDTH},height={preview_height},"
        f"pixel-aspect-ratio=1/1 {label}"
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


def start_captures(pipeline, lens_position=None):
    """Start both readers and inject frames from the GLib main thread."""
    captures = [capture(0, lens_position), capture(1, lens_position)]
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


def read_ina_u16(address, register):
    """Read one INA226 16-bit register using the raw-I2C board interface."""
    result = subprocess.run(
        ["i2ctransfer", "-f", "-y", str(INA226_BUS),
         f"w1@{address}", f"0x{register:02x}", "r2"],
        check=True, text=True, capture_output=True,
    )
    values = result.stdout.split()
    if len(values) != 2:
        raise RuntimeError(f"unexpected INA226 response: {result.stdout!r}")
    return (int(values[0], 16) << 8) | int(values[1], 16)


def ina_label(link, address):
    """Return a compact voltage/current readout for one camera power path."""
    try:
        bus_counts = read_ina_u16(address, 0x02)
        shunt_counts = read_ina_u16(address, 0x01)
        if shunt_counts & 0x8000:
            shunt_counts -= 0x10000
        voltage_v = bus_counts * 0.00125
        current_ma = shunt_counts * 0.25
        return f"{link}: {voltage_v:.3f} V  {current_ma:.2f} mA"
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        return f"{link}: INA226 read error ({error})"


def main():
    parser = argparse.ArgumentParser(description="Dual GMSL2 HDMI preview")
    parser.add_argument(
        "--ina", action="store_true",
        help="show INA226 voltage/current below each camera (run with sudo)",
    )
    parser.add_argument(
        "--lens-position", type=float, default=None,
        help="manual focus for both cameras in dioptres "
             "(0=infinity, 5=approx. 20 cm); omitted: camera default",
    )
    args = parser.parse_args()
    if args.lens_position is not None:
        if not math.isfinite(args.lens_position) or args.lens_position < 0:
            parser.error("--lens-position must be finite and non-negative")

    Gst.init(None)
    desc = " ".join((
        branch("camera0", "label0", "sink_0", args.ina),
        branch("camera1", "label1", "sink_1", args.ina),
        "compositor name=compositor "
        f"sink_0::xpos=0 sink_0::ypos={PREVIEW_Y} "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos={PREVIEW_Y} "
        f"! video/x-raw,width={DISPLAY_WIDTH},height={DISPLAY_HEIGHT},"
        "pixel-aspect-ratio=1/1 "
        "! videoconvert ! kmssink driver-name=vc4",
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
    captures = start_captures(pipeline, args.lens_position)

    if args.ina:
        labels = [pipeline.get_by_name("label0"), pipeline.get_by_name("label1")]

        def update_ina_labels():
            for label, (link, address) in zip(labels, CAMERA_INA):
                label.set_property("text", ina_label(link, address))
            return True

        update_ina_labels()
        GLib.timeout_add(1000, update_ina_labels)

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
