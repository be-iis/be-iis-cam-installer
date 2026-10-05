#!/usr/bin/env python3
"""Hold one MAX96717 manual TX-amplitude code and watch MAX96716A decode errors.

The test changes only the selected serializer's forward-link TX amplitude:
MAX96717 RLMS95 (0x1495), bit 7 enables manual amplitude and bits 5:0 select
the amplitude code. Bit 6 is preserved from the original register value.

GMSL rate and MAX96716A receiver EQ/adaptation are left untouched so this test
isolates transmitter amplitude as much as possible. The original serializer
register byte is restored at the end unless --apply is given.
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
SER_TX_AMP_REG = 0x1495

LINKS = {
    "A": dict(select_mask=0x01, des_rate_reg=0x0001, decode_reg=0x0022,
              lock_reg=0x0013, lock_mask=0x08),
    "B": dict(select_mask=0x02, des_rate_reg=0x0004, decode_reg=0x0023,
              lock_reg=0x5009, lock_mask=0x08),
}

RATE_NAMES = {0x01: "3 Gbit/s", 0x02: "6 Gbit/s"}


def parse_int(value: str) -> int:
    return int(value, 0)


class I2C:
    def __init__(self, bus: int, des_addr: int, ser_addr: int) -> None:
        self.bus = bus
        self.des_addr = des_addr
        self.ser_addr = ser_addr

    def _run(self, *args: str) -> str:
        cp = subprocess.run(
            ["i2ctransfer", "-f", "-y", str(self.bus), *args],
            check=True, text=True, capture_output=True, timeout=1.0,
        )
        return cp.stdout.strip()

    def read(self, addr: int, reg: int) -> int:
        out = self._run(
            f"w2@0x{addr:02x}",
            f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}",
            "r1",
        )
        if not re.fullmatch(r"0x[0-9a-fA-F]{2}", out):
            raise RuntimeError(
                f"unexpected I2C response at 0x{addr:02x}/0x{reg:04x}: {out!r}"
            )
        return int(out, 16)

    def write(self, addr: int, reg: int, value: int) -> None:
        self._run(
            f"w3@0x{addr:02x}",
            f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}",
            f"0x{value & 0xff:02x}",
        )

    def update(self, addr: int, reg: int, mask: int, value: int) -> None:
        old = self.read(addr, reg)
        new = (old & ~mask) | (value & mask)
        if new != old:
            self.write(addr, reg, new)


def load_profile(name: str) -> tuple[int, int, int]:
    with (ROOT / "profiles" / f"{name}.json").open(encoding="utf-8") as fh:
        profile = json.load(fh)
    return (
        int(profile["i2c_bus"]),
        int(profile["devices"]["deserializer"], 16),
        int(profile["devices"]["serializer"], 16),
    )


def select_link(io: I2C, cfg: dict[str, int]) -> None:
    """Select one reverse-I2C link using the repository's normal sequence."""
    mask = cfg["select_mask"]
    io.update(io.des_addr, 0x0F00, 0x03, mask)
    io.update(io.des_addr, 0x0010, 0x33, 0x30 | mask)
    io.update(io.des_addr, 0x0012, 0x20, 0x20)
    time.sleep(0.20)


def locked(io: I2C, cfg: dict[str, int]) -> bool:
    return bool(io.read(io.des_addr, cfg["lock_reg"]) & cfg["lock_mask"])


def wait_locked(io: I2C, cfg: dict[str, int], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if locked(io, cfg):
                return True
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    return False


def snapshot(
    io: I2C,
    cfg: dict[str, int],
    link: str,
    label: str,
    out_dir: Path,
) -> Path:
    data: dict[str, object] = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "label": label,
        "link": link,
        "bus": io.bus,
        "deserializer_address": f"0x{io.des_addr:02x}",
        "serializer_address": f"0x{io.ser_addr:02x}",
        "deserializer": {},
        "serializer": {},
    }

    for reg in (
        0x0001, 0x0004, 0x0010, 0x0012, 0x0013, 0x5009,
        0x1403, 0x1423, 0x14A4, 0x1503, 0x1523, 0x15A4,
    ):
        try:
            data["deserializer"][f"0x{reg:04x}"] = io.read(io.des_addr, reg)  # type: ignore[index]
        except Exception as error:
            data["deserializer"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    for reg in (0x0001, 0x000D, SER_TX_AMP_REG):
        try:
            data["serializer"][f"0x{reg:04x}"] = io.read(io.ser_addr, reg)  # type: ignore[index]
        except Exception as error:
            data["serializer"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    path = out_dir / f"{datetime.now():%Y%m%d-%H%M%S-%f}-{safe}.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="imx708-revb")
    parser.add_argument("--link", choices=("A", "B"), required=True)
    parser.add_argument("--code", type=parse_int, required=True,
                        help="manual TX amplitude code, 0..63")
    parser.add_argument("--dwell", type=float, default=60.0)
    parser.add_argument("--poll", type=float, default=1.0)
    parser.add_argument("--settle", type=float, default=0.25)
    parser.add_argument("--lock-timeout", type=float, default=2.0)
    parser.add_argument("--apply", action="store_true",
                        help="leave the manual TX amplitude active")
    args = parser.parse_args()

    if not 0 <= args.code <= 0x3F:
        parser.error("--code must be in range 0..63")
    if args.dwell <= 0 or args.poll <= 0 or args.settle < 0 or args.lock_timeout <= 0:
        parser.error("invalid timing value")
    if os.geteuid() != 0:
        parser.error("run as root (the Makefile target uses sudo)")

    bus, des_addr, ser_addr = load_profile(args.profile)
    cfg = LINKS[args.link]
    io = I2C(bus, des_addr, ser_addr)

    lock_path = f"/run/lock/beiis-gmsl-{bus}-{des_addr:02x}.lock"
    lock_handle = open(lock_path, "a", encoding="utf-8")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        parser.error(
            "cannot acquire GMSL monitor lock; stop dual_preview --gmsl, "
            f"eq-test or another counter reader first: {error}"
        )

    print(f"==> Select Link {args.link}", flush=True)
    select_link(io, cfg)
    if not wait_locked(io, cfg, args.lock_timeout):
        raise RuntimeError(f"Link {args.link} did not lock after selection")

    ser_rate_code = (io.read(io.ser_addr, 0x0001) >> 2) & 0x03
    des_rate_code = io.read(io.des_addr, cfg["des_rate_reg"]) & 0x03
    if ser_rate_code != des_rate_code:
        raise RuntimeError(
            f"rate mismatch before test: SER={ser_rate_code} DES={des_rate_code}"
        )
    rate_name = RATE_NAMES.get(ser_rate_code, f"rate-code {ser_rate_code}")

    original = io.read(io.ser_addr, SER_TX_AMP_REG)
    manual = (original & 0x40) | 0x80 | args.code

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = (
        ROOT / "captures" / "tx-amp-test"
        / f"{stamp}-link-{args.link}-code-{args.code:02d}"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[tuple[float, int, int, int]] = []
    total = 0
    first_error_snapshot = ""

    try:
        print(
            f"Profile={args.profile} link={args.link} rate={rate_name} "
            f"RLMS95 original=0x{original:02x} -> manual=0x{manual:02x} "
            f"(code={args.code}) dwell={args.dwell:g}s",
            flush=True,
        )
        snapshot(io, cfg, args.link, "before-manual-tx-amplitude", out_dir)

        io.write(io.ser_addr, SER_TX_AMP_REG, manual)
        observed = io.read(io.ser_addr, SER_TX_AMP_REG)
        if observed != manual:
            raise RuntimeError(
                f"RLMS95 readback mismatch: wrote 0x{manual:02x}, read 0x{observed:02x}"
            )

        time.sleep(args.settle)
        if not locked(io, cfg):
            path = snapshot(io, cfg, args.link, "lost-lock-after-amplitude", out_dir)
            print(f"LOST LOCK after amplitude change; snapshot={path.name}", flush=True)
            return 2

        # Baseline read-to-clear counter after the amplitude change.
        io.read(io.des_addr, cfg["decode_reg"])

        start = time.monotonic()
        deadline = start + args.dwell
        while time.monotonic() < deadline:
            time.sleep(min(args.poll, max(0.0, deadline - time.monotonic())))
            delta = io.read(io.des_addr, cfg["decode_reg"])
            total += delta
            is_locked = int(locked(io, cfg))
            elapsed = time.monotonic() - start
            rows.append((elapsed, delta, total, is_locked))

            if delta and not first_error_snapshot:
                path = snapshot(
                    io, cfg, args.link,
                    f"first-decode-{delta}-total-{total}",
                    out_dir,
                )
                first_error_snapshot = path.name
                print(
                    f"{elapsed:7.2f}s: DEC +{delta} total={total}; "
                    f"snapshot={path.name}",
                    flush=True,
                )
            elif delta:
                print(f"{elapsed:7.2f}s: DEC +{delta} total={total}", flush=True)

            if not is_locked:
                path = snapshot(
                    io, cfg, args.link, f"lost-lock-total-{total}", out_dir
                )
                print(
                    f"{elapsed:7.2f}s: LOST LOCK snapshot={path.name}",
                    flush=True,
                )
                return 3

        final = snapshot(
            io, cfg, args.link, f"final-total-{total}", out_dir
        )
        print(
            f"RESULT: TX_CODE={args.code} RLMS95=0x{manual:02x} "
            f"rate={rate_name} DEC={total} lock=yes dwell={args.dwell:g}s "
            f"snapshot={final.name}",
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
                f"Leaving Link {args.link} at manual TX code {args.code} "
                f"(RLMS95=0x{manual:02x}).",
                flush=True,
            )
        else:
            try:
                io.write(io.ser_addr, SER_TX_AMP_REG, original)
                restored = io.read(io.ser_addr, SER_TX_AMP_REG)
                if restored != original:
                    raise RuntimeError(
                        f"restore readback 0x{restored:02x}, expected 0x{original:02x}"
                    )
                print(
                    f"Original serializer RLMS95 restored: 0x{original:02x}",
                    flush=True,
                )
            except Exception as error:
                print(f"WARNING: serializer amplitude restore failed: {error}",
                      file=sys.stderr)

        print(f"Results: {out_dir}", flush=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, FileNotFoundError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
