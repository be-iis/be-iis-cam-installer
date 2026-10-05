#!/usr/bin/env python3
"""Run a fixed manual-EQ soak test on one MAX96716A GMSL2 link.

This disables AdaptEn and periodic AEQ, applies one BSTInit value, performs one
link reset/calibration, clears the read-to-clear decode counter, and then holds
that exact state for the requested dwell time.

No sweep and no further resets occur during the soak. The first decode-error
event triggers an RLMS snapshot.
"""

from __future__ import annotations

import argparse
import csv
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RLMS_SNAPSHOT_OFFSETS = (
    0x03, 0x04, 0x05, 0x06, 0x07, 0x0A, 0x0B, 0x18, 0x1F, 0x21, 0x23,
    0x31, 0x3E, 0x3F, 0x45, 0x46, 0x47, 0x49, 0x8C, 0x95, 0x98,
    0xA4, 0xA5, 0xA7, 0xA8, 0xA9, 0xAC, 0xAD,
)

LINKS = {
    "A": dict(rlms_base=0x1400, decode_counter=0x0022,
              lock_reg=0x0013, lock_mask=0x08, reset_reg=0x0010),
    "B": dict(rlms_base=0x1500, decode_counter=0x0023,
              lock_reg=0x5009, lock_mask=0x08, reset_reg=0x0012),
}


def parse_int(value: str) -> int:
    return int(value, 0)


class Deserializer:
    def __init__(self, bus: int, address: int) -> None:
        self.bus = bus
        self.address = address

    def _run(self, *args: str) -> str:
        cp = subprocess.run(
            ["i2ctransfer", "-f", "-y", str(self.bus), *args],
            check=True, text=True, capture_output=True, timeout=1.0,
        )
        return cp.stdout.strip()

    def read(self, reg: int) -> int:
        out = self._run(
            f"w2@0x{self.address:02x}",
            f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}",
            "r1",
        )
        if not re.fullmatch(r"0x[0-9a-fA-F]{2}", out):
            raise RuntimeError(f"unexpected I2C response at 0x{reg:04x}: {out!r}")
        return int(out, 16)

    def write(self, reg: int, value: int) -> None:
        self._run(
            f"w3@0x{self.address:02x}",
            f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}",
            f"0x{value & 0xff:02x}",
        )

    def update(self, reg: int, mask: int, value: int) -> None:
        old = self.read(reg)
        new = (old & ~mask) | (value & mask)
        if new != old:
            self.write(reg, new)


def load_profile(name: str) -> tuple[int, int]:
    with (ROOT / "profiles" / f"{name}.json").open(encoding="utf-8") as fh:
        p = json.load(fh)
    return int(p["i2c_bus"]), int(p["devices"]["deserializer"], 16)


def wait_locked(des: Deserializer, cfg: dict[str, int], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if des.read(cfg["lock_reg"]) & cfg["lock_mask"]:
                return True
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    return False


def snapshot(des: Deserializer, cfg: dict[str, int], label: str, out_dir: Path) -> Path:
    data: dict[str, object] = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "label": label,
        "bus": des.bus,
        "deserializer_address": f"0x{des.address:02x}",
        "global": {},
        "rlms": {},
    }
    for reg in (0x0001, 0x0004, 0x0010, 0x0012, 0x0013, 0x5009):
        try:
            data["global"][f"0x{reg:04x}"] = des.read(reg)  # type: ignore[index]
        except Exception as error:
            data["global"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    base = cfg["rlms_base"]
    for offset in RLMS_SNAPSHOT_OFFSETS:
        reg = base + offset
        try:
            data["rlms"][f"0x{reg:04x}"] = des.read(reg)  # type: ignore[index]
        except Exception as error:
            data["rlms"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    path = out_dir / f"{datetime.now():%Y%m%d-%H%M%S-%f}-{safe}.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="imx708-revb")
    parser.add_argument("--link", choices=("A", "B"), required=True)
    parser.add_argument("--value", type=parse_int, required=True,
                        help="BSTInit value 0..63")
    parser.add_argument("--dwell", type=float, default=60.0)
    parser.add_argument("--poll", type=float, default=1.0)
    parser.add_argument("--settle", type=float, default=0.25)
    parser.add_argument("--lock-timeout", type=float, default=2.0)
    parser.add_argument("--apply", action="store_true",
                        help="leave the tested manual-EQ setting active")
    args = parser.parse_args()

    if not 0 <= args.value <= 0x3F:
        parser.error("--value must be in range 0..63")
    if args.dwell <= 0 or args.poll <= 0 or args.settle < 0 or args.lock_timeout <= 0:
        parser.error("invalid timing value")
    if os.geteuid() != 0:
        parser.error("run as root (the Makefile target uses sudo)")

    bus, address = load_profile(args.profile)
    cfg = LINKS[args.link]
    des = Deserializer(bus, address)

    lock_path = f"/run/lock/beiis-gmsl-{bus}-{address:02x}.lock"
    lock_handle = open(lock_path, "a", encoding="utf-8")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        parser.error(f"cannot acquire GMSL monitor lock: {error}")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = ROOT / "captures" / "eq-test" / f"{stamp}-link-{args.link}-bst-{args.value:02d}"
    out_dir.mkdir(parents=True, exist_ok=True)

    base = cfg["rlms_base"]
    original = {
        "rlms3": des.read(base + 0x03),
        "rlms23": des.read(base + 0x23),
        "rlmsa4": des.read(base + 0xA4),
    }

    first_error_snapshot = ""
    total = 0
    rows: list[tuple[float, int, int, int]] = []

    try:
        print(
            f"Profile={args.profile} link={args.link} BSTInit={args.value} "
            f"dwell={args.dwell:g}s",
            flush=True,
        )
        snapshot(des, cfg, "before-fixed-eq", out_dir)

        # Manual EQ: disable global and periodic adaptation.
        des.update(base + 0x03, 0x80, 0x00)
        des.update(base + 0xA4, 0x3F, 0x00)
        des.update(base + 0x23, 0x3F, args.value)

        # Exactly one calibration/reset before the soak.
        des.update(cfg["reset_reg"], 0x20, 0x20)
        if not wait_locked(des, cfg, args.lock_timeout):
            path = snapshot(des, cfg, "no-lock", out_dir)
            print(f"NO LOCK  snapshot={path.name}", flush=True)
            return 2

        time.sleep(args.settle)

        # Baseline the read-to-clear counter after calibration.
        des.read(cfg["decode_counter"])

        start = time.monotonic()
        deadline = start + args.dwell
        while time.monotonic() < deadline:
            sleep_for = min(args.poll, max(0.0, deadline - time.monotonic()))
            time.sleep(sleep_for)
            delta = des.read(cfg["decode_counter"])
            total += delta
            locked = int(bool(des.read(cfg["lock_reg"]) & cfg["lock_mask"]))
            elapsed = time.monotonic() - start
            rows.append((elapsed, delta, total, locked))

            if delta and not first_error_snapshot:
                path = snapshot(
                    des, cfg, f"first-decode-{delta}-total-{total}", out_dir
                )
                first_error_snapshot = path.name
                print(
                    f"{elapsed:7.2f}s: DEC +{delta} total={total}; "
                    f"snapshot={path.name}",
                    flush=True,
                )
            elif delta:
                print(f"{elapsed:7.2f}s: DEC +{delta} total={total}", flush=True)

            if not locked:
                path = snapshot(des, cfg, f"lost-lock-total-{total}", out_dir)
                print(f"{elapsed:7.2f}s: LOST LOCK snapshot={path.name}", flush=True)
                return 3

        final_snapshot = snapshot(des, cfg, f"final-total-{total}", out_dir)
        print(
            f"RESULT: BSTInit={args.value} DEC={total} lock=yes "
            f"dwell={args.dwell:g}s snapshot={final_snapshot.name}",
            flush=True,
        )
        return 0 if total == 0 else 4

    finally:
        with (out_dir / "soak.csv").open("w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh)
            writer.writerow(("seconds", "decode_delta", "decode_total", "locked"))
            writer.writerows((f"{s:.3f}", d, t, l) for s, d, t, l in rows)

        if args.apply:
            print(
                f"Leaving Link {args.link} at BSTInit={args.value} with AEQ disabled.",
                flush=True,
            )
        else:
            try:
                des.write(base + 0x23, original["rlms23"])
                des.write(base + 0xA4, original["rlmsa4"])
                des.write(base + 0x03, original["rlms3"])
                des.update(cfg["reset_reg"], 0x20, 0x20)
                wait_locked(des, cfg, args.lock_timeout)
                print("Original EQ configuration restored.", flush=True)
            except Exception as error:
                print(f"WARNING: restore failed: {error}", file=sys.stderr)

        print(f"Results: {out_dir}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
