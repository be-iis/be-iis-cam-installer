#!/usr/bin/env python3
"""Dual camera HDMI preview — example implementation only."""
import argparse
import fcntl
import math
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from camera_profile import load as load_camera_profile  # noqa: E402

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst

DISPLAY_WIDTH, DISPLAY_HEIGHT = 800, 480
PREVIEW_WIDTH, PREVIEW_HEIGHT = 400, 225
PREVIEW_Y = (DISPLAY_HEIGHT - PREVIEW_HEIGHT) // 2
CAPTURE_WIDTH, CAPTURE_HEIGHT, FRAMERATE = 1024, 576, 30
FRAME_SIZE = CAPTURE_WIDTH * CAPTURE_HEIGHT * 3 // 2
SENSOR_MODE = None
INA226_BUS = 11
INA226_SHUNT_MOHM = 10

# Camera 0 is IMX708@0x53 (Link B); camera 1 is @0x52 (Link A).
CAMERA_INA = (("Link B", "0x45"), ("Link A", "0x41"))


def focus_value(value):
    if value.lower() == "auto":
        return "auto"
    try:
        position = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("use 'auto' or a non-negative number")
    if not math.isfinite(position) or position < 0:
        raise argparse.ArgumentTypeError("focus position must be finite and non-negative")
    return position


class CameraStats:
    """Host-side observations, not sensor frame counters or GMSL CRC counters."""

    def __init__(self, link, focus=None):
        self.lock = threading.Lock()
        self.link = link
        self.focus = "default" if focus is None else str(focus)
        self.frames = self.skipped = self.gaps = self.errors = self.warnings = 0
        self.last_frame = None
        self.last_gap_ms = 0.0
        self.eof = False
        self.message = ""
        self.sensor = "pending"
        self.power = "INA: off"
        self.hardware = "GMSL: off (--gmsl)"
        self.hardware_detail = ""
        self.started = self.sample_time = time.monotonic()
        self.sample_frames = 0

    def frame(self, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            if self.last_frame is not None:
                gap = now - self.last_frame
                if gap > max(0.25, 3 / FRAMERATE):
                    self.gaps += 1
                    self.last_gap_ms = gap * 1000
            self.frames += 1
            self.last_frame = now

    def skip(self):
        with self.lock:
            self.skipped += 1

    def error(self, message):
        with self.lock:
            self.errors += 1
            self.message = message

    def log(self, line):
        with self.lock:
            if re.search(r"\b(ERROR|FATAL)\b", line, re.IGNORECASE):
                self.errors += 1
                self.message = line.strip()
            elif re.search(r"\bWARN(?:ING)?\b", line, re.IGNORECASE):
                self.warnings += 1
                self.message = line.strip()
            mode = re.search(r"Selected sensor format:\s*(\S+)", line)
            if mode:
                self.sensor = mode.group(1)

    def label(self, process, now=None):
        now = time.monotonic() if now is None else now
        code = process.poll()
        with self.lock:
            elapsed = now - self.sample_time
            fps = (self.frames - self.sample_frames) / elapsed if elapsed > 0 else 0
            self.sample_time, self.sample_frames = now, self.frames
            age = now - self.last_frame if self.last_frame is not None else None
            state = "RUN"
            if code is not None:
                state = f"EXIT {code}"
            elif self.eof:
                state = "EOF"
            elif self.last_frame is None:
                state = "WAIT"
            elif age > max(1.0, 3 / FRAMERATE):
                state = "STALL"
            age_text = "--" if age is None else f"{age * 1000:.0f}ms"
            # Limit diagnostic lines to the 400-pixel panel; full logs stay on stderr.
            return "\n".join((
                f"{self.link} | {state} | Focus: {self.focus}",
                f"Out: {CAPTURE_WIDTH}x{CAPTURE_HEIGHT} | RX {fps:.1f}/{FRAMERATE} fps",
                f"Sensor: {self.sensor[:38]}",
                f"Frames {self.frames} | Preview skip {self.skipped}",
                f"RX gaps {self.gaps} | Last {self.last_gap_ms:.0f}ms | Age {age_text}",
                f"Log errors {self.errors} | Warnings {self.warnings}",
                self.power[:48],
                self.hardware,
                self.hardware_detail,
                (self.message[-48:] if self.message else ""),
            ))


def read_camera_log(process, stats):
    for raw in iter(process.stderr.readline, b""):
        line = raw.decode("utf-8", errors="replace")
        stats.log(line)
        sys.stderr.write(f"[{stats.link}] {line}")


def status_branch(name, pad):
    # An independent source keeps diagnostics updating when a camera stops.
    return (
        "videotestsrc is-live=true pattern=black "
        f"! video/x-raw,width={PREVIEW_WIDTH},height=200,framerate=5/1 "
        f'! textoverlay name={name} text="Starting..." '
        'valignment=top halignment=left font-desc="Monospace 10" '
        "xpad=6 ypad=6 wait-text=false "
        f"! queue max-size-buffers=2 leaky=downstream ! compositor.{pad}"
    )


def capture(camera, lens_position=None, monitor=False):
    return subprocess.Popen(
        [
            "rpicam-vid", "--camera", str(camera), "--nopreview",
            "--codec", "yuv420", "--width", str(CAPTURE_WIDTH),
            "--height", str(CAPTURE_HEIGHT), "--framerate", str(FRAMERATE),
            "--timeout", "0", "--output", "-",
        ] + (["--mode", SENSOR_MODE] if SENSOR_MODE else []) + (
            ["--autofocus-mode", "continuous"] if lens_position == "auto" else
            ["--autofocus-mode", "manual", "--lens-position", str(lens_position)]
            if lens_position is not None else []
        ),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if monitor else None,
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


def feed(process, frames, stats=None):
    """Read complete camera frames; never call GStreamer from this thread."""
    while True:
        data = bytearray()
        while len(data) < FRAME_SIZE:
            chunk = process.stdout.read(FRAME_SIZE - len(data))
            if not chunk:
                if stats is not None:
                    with stats.lock:
                        stats.eof = True
                    if data:
                        stats.error(f"Incomplete frame: {len(data)}/{FRAME_SIZE} bytes")
                return
            data.extend(chunk)
        if stats is not None:
            stats.frame()
        try:
            frames.put_nowait(bytes(data))
        except queue.Full:
            try:
                frames.get_nowait()
                if stats is not None:
                    stats.skip()
            except queue.Empty:
                pass
            frames.put_nowait(bytes(data))


def latest_frame(frames, stats=None):
    data = None
    while True:
        try:
            new_data = frames.get_nowait()
            if data is not None and stats is not None:
                stats.skip()
            data = new_data
        except queue.Empty:
            return data


def push_frame(appsrc, data):
    buffer = Gst.Buffer.new_allocate(None, FRAME_SIZE, None)
    buffer.fill(0, data)
    return appsrc.emit("push-buffer", buffer) == Gst.FlowReturn.OK


def start_captures(pipeline, lens_position=None, focus_a=None, focus_b=None, stats=None,
                   camera_indices=(0, 1), camera_links=("b", "a")):
    """Start both readers and inject frames from the GLib main thread."""
    captures = [
        capture(index, (focus_a if link == "a" else focus_b)
                if (focus_a if link == "a" else focus_b) is not None
                else lens_position, stats is not None)
        for index, link in zip(camera_indices, camera_links)
    ]
    frame_queues = [queue.Queue(maxsize=2), queue.Queue(maxsize=2)]
    sources = [
        (pipeline.get_by_name("camera0"), frame_queues[0]),
        (pipeline.get_by_name("camera1"), frame_queues[1]),
    ]
    observers = stats if stats is not None else [None, None]
    for process, frames, observer in zip(captures, frame_queues, observers):
        threading.Thread(target=feed, args=(process, frames, observer), daemon=True).start()
        if observer is not None:
            threading.Thread(target=read_camera_log, args=(process, observer), daemon=True).start()

    def drain_frames():
        for (appsrc, frames), observer in zip(sources, observers):
            data = latest_frame(frames, observer)
            if data is not None and not push_frame(appsrc, data):
                if observer is not None:
                    observer.error("GStreamer push-buffer failed")
                return False
        return True

    GLib.timeout_add(1, drain_frames)
    return captures


def read_ina_u16(address, register):
    """Read one INA226 16-bit register using the raw-I2C board interface."""
    result = subprocess.run(
        ["i2ctransfer", "-f", "-y", str(INA226_BUS),
         f"w1@{address}", f"0x{register:02x}", "r2"],
        check=True, text=True, capture_output=True, timeout=0.5,
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
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        return f"{link}: INA226 read error ({error})"


def poll_power(stats, stop):
    """Do not block the GLib frame delivery loop on I2C subprocesses."""
    while not stop.is_set():
        for observer, (link, address) in zip(stats, CAMERA_INA):
            value = ina_label(link, address)
            with observer.lock:
                observer.power = value
        stop.wait(1)


# MAX96716A data sheet: MIPI_TX2 (0x442/0x482), CNT0/1 (0x22/0x23).
# Link/port mapping follows tools/bringup-gmsl-links-a-b.sh.
GMSL_REGISTERS = {"Link A": (0x0442, 0x0022), "Link B": (0x0482, 0x0023)}


def read_des_u8(bus, address, register):
    result = subprocess.run(
        ["i2ctransfer", "-f", "-y", str(bus), f"w2@0x{address:02x}",
         f"0x{register >> 8:02x}", f"0x{register & 255:02x}", "r1"],
        check=True, text=True, capture_output=True, timeout=0.5,
    )
    values = result.stdout.split()
    if len(values) != 1 or not re.fullmatch(r"0x[0-9a-fA-F]{2}", values[0]):
        raise RuntimeError(f"invalid register response at 0x{register:04x}")
    return int(values[0], 16)


class GmslMonitor:
    """Accumulate read-to-clear observations without changing link configuration."""

    def __init__(self, stats, bus=11, address=0x28):
        self.stats, self.bus, self.address = stats, bus, address
        self.totals = {s.link: dict(crc=0, corr=0, uncorr=0, sync=0, dec=0) for s in stats}
        self.baselined = set()
        self.io_errors = 0

    def read(self, register):
        return read_des_u8(self.bus, self.address, register)

    def sample(self):
        # Check routing before consuming per-port read-to-clear flags.
        # Unsupported routing must never silently attribute CRCs to the wrong link.
        if (self.read(0x0160) & 3 != 3 or self.read(0x0161) != 0x20
                or self.read(0x0474) & 7 != 1 or self.read(0x04b4) & 7 != 7):
            raise RuntimeError("unsupported tunnel routing")
        for observer in self.stats:
            status_reg, dec_reg = GMSL_REGISTERS[observer.link]
            counts = self.totals[observer.link]
            status = self.read(status_reg)
            if status_reg in self.baselined:
                for name, mask in (("crc", 0x20), ("uncorr", 0x10),
                                   ("corr", 0x08), ("sync", 0x04)):
                    counts[name] += bool(status & mask)
            self.baselined.add(status_reg)
            # Commit each consumed value immediately: a later failed I2C read
            # must not discard flags already cleared by the successful read.
            decoding = self.read(dec_reg)
            if dec_reg in self.baselined:
                counts["dec"] += decoding
            self.baselined.add(dec_reg)
            with observer.lock:
                observer.hardware = (f"Tunnel CRC hits {counts['crc']} | DEC {counts['dec']}")
                observer.hardware_detail = (
                    f"ECC C/U {counts['corr']}/{counts['uncorr']} | Sync loss {counts['sync']}"
                )

    def poll(self, stop):
        while not stop.is_set():
            try:
                self.sample()
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                self.io_errors += 1
                for observer in self.stats:
                    with observer.lock:
                        observer.hardware = f"GMSL unavailable/stale | IO {self.io_errors}"
                        observer.hardware_detail = str(error)[-48:]
                if self.io_errors == 1:
                    print(f"GMSL monitor: {error}", file=sys.stderr)
            stop.wait(1)


def main():
    global CAPTURE_WIDTH, CAPTURE_HEIGHT, FRAMERATE, FRAME_SIZE, SENSOR_MODE, CAMERA_INA, INA226_BUS
    parser = argparse.ArgumentParser(description="Dual GMSL2 HDMI preview")
    parser.add_argument("--profile", default="imx708-revb",
                        help="verified camera profile (default: imx708-revb)")
    parser.add_argument("--gmsl", action="store_true",
                        help="monitor MAX96716A tunnel CRC/ECC and decoding errors (read-to-clear)")
    parser.add_argument("--gmsl-bus", type=int, default=None,
                        help="MAX96716A I2C bus (default: selected profile)")
    parser.add_argument("--gmsl-address", type=lambda value: int(value, 0), default=None,
                        help="MAX96716A 7-bit I2C address (default: selected profile)")
    parser.add_argument("--width", type=int, default=1024,
                        help="capture output width, multiple of 32 (default: 1024)")
    parser.add_argument("--height", type=int, default=576,
                        help="capture output height, even (default: 576)")
    parser.add_argument("--framerate", type=int, default=30,
                        help="requested frames per second, positive integer (default: 30)")
    parser.add_argument("--mode", default=None,
                        help="sensor mode WIDTH:HEIGHT[:BITS[:P|U]]; omitted: automatic")
    parser.add_argument(
        "--ina", action="store_true",
        help="show INA226 voltage/current below each camera (run with sudo)",
    )
    parser.add_argument(
        "--lens-position", type=focus_value, default=None,
        help="focus for both cameras: auto or dioptres "
             "(0=infinity, 5=approx. 20 cm); omitted: camera default",
    )
    parser.add_argument(
        "--focus-a", type=focus_value, default=None,
        help="Link A (camera 1): auto or dioptres; overrides --lens-position",
    )
    parser.add_argument(
        "--focus-b", type=focus_value, default=None,
        help="Link B (camera 0): auto or dioptres; overrides --lens-position",
    )
    args = parser.parse_args()
    try:
        selected = load_camera_profile(args.profile)
    except (OSError, ValueError, KeyError) as error:
        parser.error(f"invalid camera profile: {error}")
    indices = selected["capture"]["camera_indices"]
    links = selected["capture"]["links"]
    INA226_BUS = selected["i2c_bus"]
    if args.ina:
        try:
            CAMERA_INA = tuple(("Link " + link.upper(), selected["links"][link]["ina_address"])
                               for link in links)
        except KeyError:
            parser.error("selected profile has no INA226 addresses")
    if args.gmsl_bus is None:
        args.gmsl_bus = selected["i2c_bus"]
    if args.gmsl_address is None:
        args.gmsl_address = int(selected["devices"]["deserializer"], 16)
    if args.gmsl_bus != selected["i2c_bus"] or args.gmsl_address != int(selected["devices"]["deserializer"], 16):
        parser.error("GMSL monitor bus/address must match the selected profile")
    if args.gmsl_bus < 0 or not 0x08 <= args.gmsl_address <= 0x77:
        parser.error("invalid GMSL I2C bus or 7-bit address")
    gmsl_lock = None
    if args.gmsl:
        # Only one cooperating monitor may consume read-to-clear flags.
        try:
            gmsl_lock = open(f"/run/lock/beiis-gmsl-{args.gmsl_bus}-{args.gmsl_address:02x}.lock", "a")
            fcntl.flock(gmsl_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if gmsl_lock is not None:
                gmsl_lock.close()
            parser.error(f"cannot acquire GMSL monitor lock (run with sudo; one monitor only): {error}")
    if args.width <= 0 or args.width % 32:
        parser.error("--width must be a positive multiple of 32")
    if args.height <= 0 or args.height % 2:
        parser.error("--height must be positive and even")
    if args.framerate <= 0:
        parser.error("--framerate must be positive")
    if args.mode is not None and not re.fullmatch(
        r"[1-9][0-9]*:[1-9][0-9]*(?::[1-9][0-9]*(?::[PU])?)?", args.mode
    ):
        parser.error("--mode must be WIDTH:HEIGHT[:BITS[:P|U]]")

    # Configure frame readers and GStreamer before any capture threads start.
    CAPTURE_WIDTH, CAPTURE_HEIGHT = args.width, args.height
    FRAMERATE, SENSOR_MODE = args.framerate, args.mode
    FRAME_SIZE = CAPTURE_WIDTH * CAPTURE_HEIGHT * 3 // 2
    print(f"Capture per camera: {CAPTURE_WIDTH}x{CAPTURE_HEIGHT}, "
          f"{FRAMERATE} fps requested, {FRAME_SIZE} bytes/frame; "
          f"sensor mode: {SENSOR_MODE or 'automatic'}", flush=True)

    Gst.init(None)
    desc = " ".join((
        branch("camera0", "label0", "sink_0", False),
        branch("camera1", "label1", "sink_1", False),
        status_branch("status0", "sink_2"),
        status_branch("status1", "sink_3"),
        "compositor name=compositor "
        "sink_0::xpos=0 sink_0::ypos=40 "
        f"sink_1::xpos={PREVIEW_WIDTH} sink_1::ypos=40 "
        "sink_2::xpos=0 sink_2::ypos=265 "
        f"sink_3::xpos={PREVIEW_WIDTH} sink_3::ypos=265 "
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
    stats = [CameraStats("Link " + link.upper(),
                        (args.focus_a if link == "a" else args.focus_b)
                        if (args.focus_a if link == "a" else args.focus_b) is not None
                        else args.lens_position) for link in links]
    captures = start_captures(pipeline, args.lens_position, args.focus_a, args.focus_b,
                              stats, indices, links)
    labels = [pipeline.get_by_name("status0"), pipeline.get_by_name("status1")]
    stop_power = threading.Event()
    power_thread = None
    if args.ina:
        for observer in stats:
            observer.power = "INA: reading..."
        power_thread = threading.Thread(target=poll_power, args=(stats, stop_power), daemon=True)
        power_thread.start()

    gmsl_thread = None
    if args.gmsl:
        for observer in stats:
            observer.hardware = "GMSL: baselining..."
        gmsl_thread = threading.Thread(
            target=GmslMonitor(stats, args.gmsl_bus, args.gmsl_address).poll,
            args=(stop_power,), daemon=True,
        )
        gmsl_thread.start()

    def update_status():
        for label, observer, process in zip(labels, stats, captures):
            label.set_property("text", observer.label(process))
        return True

    update_status()
    GLib.timeout_add(1000, update_status)

    try:
        loop.run()
    finally:
        stop_power.set()
        if power_thread is not None:
            power_thread.join(timeout=3)
        if gmsl_thread is not None:
            gmsl_thread.join(timeout=5)
        if gmsl_lock is not None:
            gmsl_lock.close()
        pipeline.set_state(Gst.State.NULL)
        for process in captures:
            process.terminate()
        for process in captures:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
