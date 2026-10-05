#!/usr/bin/env python3
"""Switch BE-IIS MAX96716A/MAX96717 GMSL2 links between 3 and 6 Gbit/s.

The currently selected serializer is programmed first while the old link is
still alive. The local MAX96716A receive rate is then changed and the selected
link is reset/re-locked at the new rate. This avoids relying on serializer
power-on strap defaults.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RATE_CODE = {3: 0x01, 6: 0x02}


@dataclass(frozen=True)
class Link:
    name: str
    select_mask: int
    des_rate_reg: int
    decode_reg: int
    lock_reg: int
    lock_mask: int
    reset_reg: int
    rlms3_reg: int


LINKS = {
    "A": Link("A", 0x01, 0x0001, 0x0022, 0x0013, 0x08, 0x0010, 0x1403),
    "B": Link("B", 0x02, 0x0004, 0x0023, 0x5009, 0x08, 0x0012, 0x1503),
}


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
            f"w2@0x{addr:02x}", f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}", "r1",
        )
        if not re.fullmatch(r"0x[0-9a-fA-F]{2}", out):
            raise RuntimeError(f"unexpected read at 0x{addr:02x}/0x{reg:04x}: {out!r}")
        return int(out, 16)

    def write(self, addr: int, reg: int, value: int) -> None:
        self._run(
            f"w3@0x{addr:02x}", f"0x{reg >> 8:02x}",
            f"0x{reg & 0xff:02x}", f"0x{value & 0xff:02x}",
        )

    def update(self, addr: int, reg: int, mask: int, value: int) -> tuple[int, int]:
        old = self.read(addr, reg)
        new = (old & ~mask) | (value & mask)
        if new != old:
            self.write(addr, reg, new)
        return old, self.read(addr, reg)


def load_profile(name: str) -> tuple[int, int, int]:
    with (ROOT / "profiles" / f"{name}.json").open(encoding="utf-8") as fh:
        p = json.load(fh)
    return p["i2c_bus"], int(p["devices"]["deserializer"], 16), int(p["devices"]["serializer"], 16)


def select_link(io: I2C, mask: int) -> None:
    io.update(io.des_addr, 0x0F00, 0x03, mask)
    io.update(io.des_addr, 0x0010, 0x33, 0x30 | mask)
    io.update(io.des_addr, 0x0012, 0x20, 0x20)
    time.sleep(0.20)


def reset_link(io: I2C, link: Link) -> None:
    io.update(io.des_addr, link.reset_reg, 0x20, 0x20)


def locked_at(io: I2C, link: Link, rate: int) -> bool:
    return (
        bool(io.read(io.des_addr, link.lock_reg) & link.lock_mask)
        and (io.read(io.des_addr, link.des_rate_reg) & 0x03) == RATE_CODE[rate]
    )


def wait_lock(io: I2C, link: Link, rate: int, timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if locked_at(io, link, rate):
                return True
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    return False


def serializer_rate(io: I2C) -> int:
    return (io.read(io.ser_addr, 0x0001) >> 2) & 0x03


def switch_one(io: I2C, link: Link, rate: int, verify_seconds: float) -> None:
    code = RATE_CODE[rate]
    print(f"==> Link {link.name}: select current link", flush=True)
    select_link(io, link.select_mask)

    ser_before = io.read(io.ser_addr, 0x0001)
    des_before = io.read(io.des_addr, link.des_rate_reg) & 0x03
    print(
        f"    before: SER TX_RATE={(ser_before >> 2) & 3} "
        f"DES RX_RATE={des_before}",
        flush=True,
    )

    # Change the remote transmitter while communication still uses the old rate.
    # This write itself completes before the link changes frequency.
    ser_after = (ser_before & ~0x0C) | (code << 2)
    if ser_after != ser_before:
        io.write(io.ser_addr, 0x0001, ser_after)

    # The serializer can now be temporarily unreachable. Local DES access is
    # independent, so set the matching RX rate and force calibration/re-lock.
    io.update(io.des_addr, link.des_rate_reg, 0x03, code)
    reset_link(io, link)

    if not wait_lock(io, link, rate):
        raise RuntimeError(f"Link {link.name} did not lock at {rate} Gbit/s")

    # Adaptation is disabled by a link reset on some sequences; explicitly
    # restore the project's normal receiver-adaptation handoff.
    io.update(io.des_addr, link.rlms3_reg, 0x80, 0x80)

    # Verify the remote serializer is really transmitting at the requested rate.
    observed_ser = serializer_rate(io)
    observed_des = io.read(io.des_addr, link.des_rate_reg) & 0x03
    if observed_ser != code or observed_des != code:
        raise RuntimeError(
            f"Link {link.name} rate mismatch after switch: "
            f"SER={observed_ser} DES={observed_des} expected={code}"
        )

    # Decode counters are read-to-clear. Establish a clean baseline, dwell, then
    # report errors without treating them as a rate-switch failure.
    io.read(io.des_addr, link.decode_reg)
    if verify_seconds > 0:
        time.sleep(verify_seconds)
    dec = io.read(io.des_addr, link.decode_reg)
    print(
        f"    Link {link.name}: LOCK {rate} Gbit/s | "
        f"SER={observed_ser} DES={observed_des} | DEC={dec} "
        f"over {verify_seconds:g}s",
        flush=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="imx708-revb")
    parser.add_argument("--rate", type=int, choices=(3, 6), required=True)
    parser.add_argument("--link", choices=("A", "B", "AB"), default="AB")
    parser.add_argument(
        "--verify-seconds", type=float, default=2.0,
        help="decode-error dwell after each link switch (default: 2 s)",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        parser.error("run as root (the Makefile targets use sudo)")
    if args.verify_seconds < 0:
        parser.error("--verify-seconds must be >= 0")

    bus, des_addr, ser_addr = load_profile(args.profile)
    io = I2C(bus, des_addr, ser_addr)

    lock_path = f"/run/lock/beiis-gmsl-{bus}-{des_addr:02x}.lock"
    lock_handle = open(lock_path, "a", encoding="utf-8")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        parser.error(
            "cannot acquire GMSL monitor lock; stop dual_preview --gmsl, "
            f"eq-sweep or another counter reader first: {error}"
        )

    names = ("A", "B") if args.link == "AB" else (args.link,)
    for name in names:
        switch_one(io, LINKS[name], args.rate, args.verify_seconds)

    if args.link == "AB":
        print("==> Restore dual-link selection", flush=True)
        select_link(io, 0x03)
        for name in names:
            io.update(io.des_addr, LINKS[name].rlms3_reg, 0x80, 0x80)

    print(f"GMSL2 mode: {args.rate} Gbit/s ({args.link})", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, FileNotFoundError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
