#!/usr/bin/env python3
"""Test the MAX96716A 6 Gbit/s long-channel errata settings on one link.

Analog Devices MAX96716A/MAX96716F Errata item "6Gbps Long Channel operation
requires register writes" prescribes:
  RLMS1F = 0x8C  (initial gain)
  RLMS23 = 0x58  (initial boost)
followed by RESET_ONESHOT for the selected link.

This tool verifies the link is currently configured for 6 Gbit/s, applies those
two writes exactly, performs one one-shot reset, clears the selected read-to-clear
decode counter, and soaks the link for the requested dwell time.

The exact original RLMS1F/RLMS23 bytes are restored afterwards unless --apply
is given.
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

LINKS = {
    "A": dict(
        rlms_base=0x1400,
        rate_reg=0x0001,
        decode_reg=0x0022,
        lock_reg=0x0013,
        lock_mask=0x08,
        reset_reg=0x0010,
    ),
    "B": dict(
        rlms_base=0x1500,
        rate_reg=0x0004,
        decode_reg=0x0023,
        lock_reg=0x5009,
        lock_mask=0x08,
        reset_reg=0x0012,
    ),
}


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


def snapshot(
    des: Deserializer,
    cfg: dict[str, int],
    link: str,
    label: str,
    out_dir: Path,
) -> Path:
    data: dict[str, object] = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "label": label,
        "link": link,
        "bus": des.bus,
        "deserializer_address": f"0x{des.address:02x}",
        "registers": {},
    }

    regs = [
        0x0001, 0x0004, 0x0010, 0x0012, 0x0013, 0x5009,
        cfg["rlms_base"] + 0x03,
        cfg["rlms_base"] + 0x1F,
        cfg["rlms_base"] + 0x23,
        cfg["rlms_base"] + 0xA4,
    ]
    for reg in regs:
        try:
            data["registers"][f"0x{reg:04x}"] = des.read(reg)  # type: ignore[index]
        except Exception as error:
            data["registers"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    path = out_dir / f"{datetime.now():%Y%m%d-%H%M%S-%f}-{safe}.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="imx708-revb")
    parser.add_argument("--link", choices=("A", "B"), required=True)
    parser.add_argument("--dwell", type=float, default=60.0)
    parser.add_argument("--poll", type=float, default=1.0)
    parser.add_argument("--settle", type=float, default=0.25)
    parser.add_argument("--lock-timeout", type=float, default=3.0)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="leave RLMS1F=0x8c / RLMS23=0x58 active after the test",
    )
    args = parser.parse_args()

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
        parser.error(
            "cannot acquire GMSL monitor lock; stop dual_preview --gmsl, "
            f"eq-test/tx-amp-test or another counter reader first: {error}"
        )

    rate_code = des.read(cfg["rate_reg"]) & 0x03
    if rate_code != 0x02:
        raise RuntimeError(
            f"Link {args.link} is not at 6 Gbit/s "
            f"(rate code={rate_code}, expected 2)"
        )

    base = cfg["rlms_base"]
    original_1f = des.read(base + 0x1F)
    original_23 = des.read(base + 0x23)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = (
        ROOT / "captures" / "long-channel-test"
        / f"{stamp}-link-{args.link}"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[tuple[float, int, int, int]] = []
    total = 0

    try:
        print(
            f"Profile={args.profile} link={args.link} rate=6 Gbit/s "
            f"RLMS1F 0x{original_1f:02x}->0x8c "
            f"RLMS23 0x{original_23:02x}->0x58 "
            f"dwell={args.dwell:g}s",
            flush=True,
        )
        snapshot(des, cfg, args.link, "before-long-channel-workaround", out_dir)

        # ADI errata: exact full-byte writes, then one-shot reset.
        des.write(base + 0x1F, 0x8C)
        des.write(base + 0x23, 0x58)

        rb_1f = des.read(base + 0x1F)
        rb_23 = des.read(base + 0x23)
        if rb_1f != 0x8C or rb_23 != 0x58:
            raise RuntimeError(
                f"errata write readback mismatch: RLMS1F=0x{rb_1f:02x}, "
                f"RLMS23=0x{rb_23:02x}"
            )

        des.update(cfg["reset_reg"], 0x20, 0x20)
        if not wait_locked(des, cfg, args.lock_timeout):
            path = snapshot(des, cfg, args.link, "no-lock-after-workaround", out_dir)
            print(f"NO LOCK after errata writes; snapshot={path.name}", flush=True)
            return 2

        time.sleep(args.settle)
        des.read(cfg["decode_reg"])  # read-to-clear baseline

        start = time.monotonic()
        deadline = start + args.dwell
        first_error_saved = False

        while time.monotonic() < deadline:
            time.sleep(min(args.poll, max(0.0, deadline - time.monotonic())))
            delta = des.read(cfg["decode_reg"])
            total += delta
            is_locked = int(bool(des.read(cfg["lock_reg"]) & cfg["lock_mask"]))
            elapsed = time.monotonic() - start
            rows.append((elapsed, delta, total, is_locked))

            if delta and not first_error_saved:
                path = snapshot(
                    des, cfg, args.link,
                    f"first-decode-{delta}-total-{total}",
                    out_dir,
                )
                first_error_saved = True
                print(
                    f"{elapsed:7.2f}s: DEC +{delta} total={total}; "
                    f"snapshot={path.name}",
                    flush=True,
                )
            elif delta:
                print(f"{elapsed:7.2f}s: DEC +{delta} total={total}", flush=True)

            if not is_locked:
                path = snapshot(
                    des, cfg, args.link, f"lost-lock-total-{total}", out_dir
                )
                print(
                    f"{elapsed:7.2f}s: LOST LOCK snapshot={path.name}",
                    flush=True,
                )
                return 3

        final = snapshot(
            des, cfg, args.link, f"final-total-{total}", out_dir
        )
        print(
            f"RESULT: LONG_CHANNEL=on DEC={total} lock=yes "
            f"dwell={args.dwell:g}s snapshot={final.name}",
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
                f"Leaving Link {args.link} with RLMS1F=0x8c / RLMS23=0x58.",
                flush=True,
            )
        else:
            try:
                des.write(base + 0x1F, original_1f)
                des.write(base + 0x23, original_23)
                des.update(cfg["reset_reg"], 0x20, 0x20)
                wait_locked(des, cfg, args.lock_timeout)
                print(
                    f"Original long-channel registers restored: "
                    f"RLMS1F=0x{original_1f:02x} RLMS23=0x{original_23:02x}",
                    flush=True,
                )
            except Exception as error:
                print(f"WARNING: restore failed: {error}", file=sys.stderr)

        print(f"Results: {out_dir}", flush=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, FileNotFoundError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
