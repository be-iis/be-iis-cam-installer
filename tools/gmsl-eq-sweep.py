#!/usr/bin/env python3
"""Characterize MAX96716A manual RX boost against the decode-error counter.

The tool disables adaptive equalization for one selected GMSL2 link, sweeps the
documented BSTInit field (RLMS23[5:0]), and uses the MAX96716A decode-error
counter as the pass/fail criterion.

Important: BSTInit is the *initial* receiver boost used during link calibration,
not a readable "current AEQ coefficient". Each trial therefore performs a
one-shot link reset so the requested BSTInit value takes effect.

The GMSL decode counter can be tested without a camera stream. If a stream is
running, expect the per-setting one-shot resets to interrupt it. Do not run
another process that consumes the read-to-clear GMSL counters.
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
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Documented MAX96716A RLMS registers worth capturing with each event.
RLMS_SNAPSHOT_OFFSETS = (
    0x03, 0x04, 0x05, 0x06, 0x07, 0x0A, 0x0B, 0x18, 0x1F, 0x21, 0x23,
    0x31, 0x3E, 0x3F, 0x45, 0x46, 0x47, 0x49, 0x8C, 0x95, 0x98,
    0xA4, 0xA5, 0xA7, 0xA8, 0xA9, 0xAC, 0xAD,
)


@dataclass(frozen=True)
class LinkRegs:
    name: str
    rlms_base: int
    decode_counter: int
    lock_reg: int
    lock_mask: int
    reset_reg: int


LINKS = {
    "A": LinkRegs("A", 0x1400, 0x0022, 0x0013, 0x08, 0x0010),
    "B": LinkRegs("B", 0x1500, 0x0023, 0x5009, 0x08, 0x0012),
}


def parse_int(value: str) -> int:
    return int(value, 0)


class Deserializer:
    def __init__(self, bus: int, address: int) -> None:
        self.bus = bus
        self.address = address

    def _run(self, *args: str) -> str:
        result = subprocess.run(
            ["i2ctransfer", "-f", "-y", str(self.bus), *args],
            check=True,
            text=True,
            capture_output=True,
            timeout=1.0,
        )
        return result.stdout.strip()

    def read(self, register: int) -> int:
        out = self._run(
            f"w2@0x{self.address:02x}",
            f"0x{register >> 8:02x}",
            f"0x{register & 0xff:02x}",
            "r1",
        )
        if not re.fullmatch(r"0x[0-9a-fA-F]{2}", out):
            raise RuntimeError(
                f"unexpected I2C response for 0x{register:04x}: {out!r}"
            )
        return int(out, 16)

    def write(self, register: int, value: int) -> None:
        self._run(
            f"w3@0x{self.address:02x}",
            f"0x{register >> 8:02x}",
            f"0x{register & 0xff:02x}",
            f"0x{value & 0xff:02x}",
        )

    def update(self, register: int, mask: int, value: int) -> tuple[int, int]:
        old = self.read(register)
        new = (old & ~mask) | (value & mask)
        if new != old:
            self.write(register, new)
        return old, self.read(register)


def load_profile(name: str) -> tuple[int, int]:
    path = ROOT / "profiles" / f"{name}.json"
    with path.open("r", encoding="utf-8") as handle:
        profile = json.load(handle)
    return int(profile["i2c_bus"]), int(profile["devices"]["deserializer"], 16)


def snapshot(des: Deserializer, regs: LinkRegs, label: str, out_dir: Path) -> Path:
    data: dict[str, object] = {
        "timestamp": datetime.now().astimezone().isoformat(timespec="milliseconds"),
        "label": label,
        "link": regs.name,
        "bus": des.bus,
        "deserializer_address": f"0x{des.address:02x}",
        "global": {},
        "rlms": {},
    }

    global_regs = (0x0001, 0x0010, 0x0012, 0x0013, 0x0018, 0x001B, 0x5009)
    for reg in global_regs:
        try:
            data["global"][f"0x{reg:04x}"] = des.read(reg)  # type: ignore[index]
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            data["global"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    for offset in RLMS_SNAPSHOT_OFFSETS:
        reg = regs.rlms_base + offset
        try:
            data["rlms"][f"0x{reg:04x}"] = des.read(reg)  # type: ignore[index]
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            data["rlms"][f"0x{reg:04x}"] = f"ERROR: {error}"  # type: ignore[index]

    safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    path = out_dir / f"{datetime.now():%Y%m%d-%H%M%S-%f}-{safe_label}.json"
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def wait_locked(des: Deserializer, regs: LinkRegs, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if des.read(regs.lock_reg) & regs.lock_mask:
                return True
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        time.sleep(0.05)
    return False


def configure_manual_eq(des: Deserializer, regs: LinkRegs) -> None:
    # RLMS3[7] AdaptEn = 0: disable the global adaptation process.
    des.update(regs.rlms_base + 0x03, 0x80, 0x00)
    # RLMSA4[5:0] AEQ_PER = 0: disable periodic adaptation.
    des.update(regs.rlms_base + 0xA4, 0x3F, 0x00)


def set_bstinit(des: Deserializer, regs: LinkRegs, value: int) -> None:
    if not 0 <= value <= 0x3F:
        raise ValueError("BSTInit must be in range 0..63")
    des.update(regs.rlms_base + 0x23, 0x3F, value)


def oneshot_reset(des: Deserializer, regs: LinkRegs) -> None:
    # RESET_ONESHOT for A is CTRL0[5]; for B it is CTRL2[5].
    des.update(regs.reset_reg, 0x20, 0x20)


@dataclass
class Trial:
    value: int
    errors: int
    locked: bool
    seconds: float
    first_error_snapshot: str = ""

    @property
    def passed(self) -> bool:
        return self.locked and self.errors == 0


def run_trial(
    des: Deserializer,
    regs: LinkRegs,
    value: int,
    dwell: float,
    poll: float,
    settle: float,
    lock_timeout: float,
    out_dir: Path,
) -> Trial:
    set_bstinit(des, regs, value)
    oneshot_reset(des, regs)

    locked = wait_locked(des, regs, lock_timeout)
    if not locked:
        path = snapshot(des, regs, f"bst-{value:02d}-no-lock", out_dir)
        print(f"BSTInit {value:02d}: NO LOCK  snapshot={path.name}", flush=True)
        return Trial(value, 0, False, 0.0, path.name)

    time.sleep(settle)

    # Read-to-clear: discard everything that happened during re-lock/settling.
    des.read(regs.decode_counter)

    errors = 0
    first_error_snapshot = ""
    start = time.monotonic()
    deadline = start + dwell
    while time.monotonic() < deadline:
        time.sleep(min(poll, max(0.0, deadline - time.monotonic())))
        delta = des.read(regs.decode_counter)
        if delta:
            errors += delta
            if not first_error_snapshot:
                path = snapshot(
                    des, regs, f"bst-{value:02d}-first-decode-{delta}", out_dir
                )
                first_error_snapshot = path.name
                print(
                    f"BSTInit {value:02d}: decode +{delta}; "
                    f"snapshot={path.name}",
                    flush=True,
                )

    locked = bool(des.read(regs.lock_reg) & regs.lock_mask)
    elapsed = time.monotonic() - start
    state = "PASS" if locked and errors == 0 else "FAIL"
    print(
        f"BSTInit {value:02d}: {state}  DEC={errors}  "
        f"lock={'yes' if locked else 'no'}  {elapsed:.2f}s",
        flush=True,
    )
    return Trial(value, errors, locked, elapsed, first_error_snapshot)


def write_csv(path: Path, trials: list[Trial]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            ("bstinit", "pass", "decode_errors", "locked", "seconds",
             "first_error_snapshot")
        )
        for trial in trials:
            writer.writerow(
                (
                    trial.value,
                    int(trial.passed),
                    trial.errors,
                    int(trial.locked),
                    f"{trial.seconds:.3f}",
                    trial.first_error_snapshot,
                )
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Disable MAX96716A AEQ on one link, sweep BSTInit around a known-good "
            "value, and choose the middle of the zero-decode-error window."
        )
    )
    parser.add_argument("--profile", default="imx708-revb")
    parser.add_argument("--link", choices=("A", "B"), required=True)
    parser.add_argument(
        "--start",
        type=parse_int,
        default=0x18,
        help=(
            "starting BSTInit value, 0..63 (default: 0x18, the 6 Gbps "
            "long-channel starting boost from the MAX96716A errata)"
        ),
    )
    parser.add_argument("--dwell", type=float, default=5.0,
                        help="error-counting time per setting in seconds")
    parser.add_argument("--poll", type=float, default=0.10,
                        help="decode-counter polling interval in seconds")
    parser.add_argument("--settle", type=float, default=0.25,
                        help="delay after link re-lock before counters are cleared")
    parser.add_argument("--lock-timeout", type=float, default=2.0)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="leave the calculated midpoint active with AEQ disabled",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="result directory (default: captures/eq-sweep/<timestamp>-link-X)",
    )
    args = parser.parse_args()

    if not 0 <= args.start <= 0x3F:
        parser.error("--start must be in range 0..63")
    if args.dwell <= 0 or args.poll <= 0 or args.settle < 0 or args.lock_timeout <= 0:
        parser.error("timing values must be positive (settle may be zero)")
    if os.geteuid() != 0:
        parser.error("run as root (the Makefile target uses sudo)")

    bus, address = load_profile(args.profile)
    if not 0x08 <= address <= 0x77:
        parser.error("profile contains an invalid 7-bit deserializer address")

    regs = LINKS[args.link]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = (
        Path(args.output_dir)
        if args.output_dir
        else ROOT / "captures" / "eq-sweep" / f"{stamp}-link-{args.link}"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    lock_path = f"/run/lock/beiis-gmsl-{bus}-{address:02x}.lock"
    lock_handle = open(lock_path, "a", encoding="utf-8")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        parser.error(
            "cannot acquire GMSL monitor lock; stop dual_preview --gmsl or any "
            f"other counter reader first: {error}"
        )

    des = Deserializer(bus, address)
    original = {
        "rlms3": des.read(regs.rlms_base + 0x03),
        "rlms23": des.read(regs.rlms_base + 0x23),
        "rlmsa4": des.read(regs.rlms_base + 0xA4),
    }
    (out_dir / "original.json").write_text(
        json.dumps(
            {
                "profile": args.profile,
                "link": args.link,
                "bus": bus,
                "address": f"0x{address:02x}",
                **{key: f"0x{value:02x}" for key, value in original.items()},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    trials: list[Trial] = []
    tested: dict[int, Trial] = {}

    def trial(value: int) -> Trial:
        if value not in tested:
            tested[value] = run_trial(
                des, regs, value, args.dwell, args.poll, args.settle,
                args.lock_timeout, out_dir
            )
            trials.append(tested[value])
        return tested[value]

    midpoint: int | None = None
    try:
        print(
            f"Profile={args.profile} link={args.link} bus={bus} "
            f"des=0x{address:02x} start={args.start}",
            flush=True,
        )
        snapshot(des, regs, "before-manual-eq", out_dir)
        configure_manual_eq(des, regs)
        snapshot(des, regs, "manual-eq-enabled", out_dir)

        start_trial = trial(args.start)
        if not start_trial.passed:
            print(
                "\nStarting point is not error-free; no bounded good window can "
                "be inferred. Re-run with a known-good --start value.",
                file=sys.stderr,
            )
            return 3

        low = high = args.start

        # Walk upward until the first failure, or until the field maximum.
        for value in range(args.start + 1, 0x40):
            result = trial(value)
            if not result.passed:
                break
            high = value

        # Walk downward independently from the known-good start.
        for value in range(args.start - 1, -1, -1):
            result = trial(value)
            if not result.passed:
                break
            low = value

        midpoint = (low + high) // 2
        print(
            f"\nError-free BSTInit window: {low}..{high}; midpoint={midpoint}",
            flush=True,
        )

        # Re-apply midpoint and verify it one more time, independently of the
        # cached sweep result.
        final = run_trial(
            des, regs, midpoint, args.dwell, args.poll, args.settle,
            args.lock_timeout, out_dir
        )
        trials.append(final)
        if not final.passed:
            print(
                "Midpoint verification failed; results are not stable enough to "
                "apply automatically.",
                file=sys.stderr,
            )
            midpoint = None
            return 4

        snapshot(des, regs, f"selected-midpoint-{midpoint:02d}", out_dir)
        return 0
    finally:
        csv_path = out_dir / "sweep.csv"
        write_csv(csv_path, trials)

        if args.apply and midpoint is not None:
            configure_manual_eq(des, regs)
            set_bstinit(des, regs, midpoint)
            oneshot_reset(des, regs)
            wait_locked(des, regs, args.lock_timeout)
            print(
                f"Leaving Link {args.link} at BSTInit={midpoint} with AEQ disabled.",
                flush=True,
            )
        else:
            # Restore the exact register bytes and re-calibrate the link.
            try:
                des.write(regs.rlms_base + 0x23, original["rlms23"])
                des.write(regs.rlms_base + 0xA4, original["rlmsa4"])
                des.write(regs.rlms_base + 0x03, original["rlms3"])
                oneshot_reset(des, regs)
                wait_locked(des, regs, args.lock_timeout)
                print("Original EQ configuration restored.", flush=True)
            except Exception as error:
                print(f"WARNING: failed to restore original EQ state: {error}", file=sys.stderr)

        print(f"Results: {out_dir}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
