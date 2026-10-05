#!/usr/bin/env python3
"""Run a reviewed BE-IIS camera profile. No executable code is read from JSON."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PROFILES = ROOT / "profiles"
HEX = re.compile(r"^0x[0-9a-fA-F]{1,4}$")


def number(value):
    if not isinstance(value, str) or not HEX.fullmatch(value):
        raise ValueError(f"Expected hexadecimal value, got {value!r}")
    return int(value, 16)


def profile(name):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name):
        raise ValueError("Invalid profile name")
    path = PROFILES / (name + ".json")
    data = json.loads(path.read_text())
    if data["id"] != name or data["status"] != "verified":
        raise ValueError("Only verified profiles with matching IDs can be selected")
    if data["schema"] != 1 or set(data["links"]) != {"a", "b"}:
        raise ValueError("Unsupported profile schema or link layout")
    for name in data["overlays"].values():
        if not re.fullmatch(r"[a-z0-9-]+", name) or not (ROOT / "overlays" / (name + ".dts")).is_file():
            raise ValueError(f"Missing or invalid overlay: {name}")
    for phase in ("init", "sensor_power", "serializer_csi", "deserializer_a", "deserializer_b", "route_a", "route_ab"):
        if not isinstance(data["pipeline"][phase], list):
            raise ValueError(f"Missing pipeline phase: {phase}")
        for step in data["pipeline"][phase]:
            if not isinstance(step.get("description"), str) or not step["description"].strip():
                raise ValueError(f"Missing step description in {phase}")
            if step["op"] not in ("write", "update", "sleep"):
                raise ValueError(f"Unsupported step: {step}")
            if step["op"] == "sleep":
                if not isinstance(step["seconds"], (int, float)) or not 0 <= step["seconds"] <= 2:
                    raise ValueError("Invalid sleep interval")
            else:
                if step["device"] not in ("deserializer", "serializer"):
                    raise ValueError("Invalid device")
                number(step["register"])
                number(step["value"])
                if step["op"] == "update":
                    number(step["mask"])
    for link in ("a", "b"):
        for field in ("sensor_alias", "focus_alias"):
            if not 0 < number(data["links"][link][field]) < 0x80:
                raise ValueError("Invalid I2C alias")
        for phase in ("init", "post_reset"):
            for step in data["links"][link][phase]:
                if step["op"] != "update" or step["device"] != "deserializer":
                    raise ValueError("Invalid per-link initialization step")
                if not isinstance(step.get("description"), str) or not step["description"].strip():
                    raise ValueError(f"Missing step description in link {link} {phase}")
                for field in ("register", "mask", "value"):
                    number(step[field])
                if "verify_mask" in step:
                    number(step["verify_mask"])
    for field in ("address", "focus_address"):
        if not 0 < number(data["sensor"][field]) < 0x80:
            raise ValueError("Invalid remote I2C address")
    if not re.fullmatch(r"[a-z][a-z0-9-]*", data["install"]["driver_target"]):
        raise ValueError("Invalid installer target")
    return data


def command(*args, capture=False):
    return subprocess.run(args, check=True, text=True, capture_output=capture)


class Bus:
    def __init__(self, data):
        self.bus = str(data["i2c_bus"])
        self.addresses = {key: number(data["devices"][key]) for key in ("serializer", "deserializer")}

    def transfer(self, address, register, count=0, value=None):
        args = ["i2ctransfer", "-f", "-y", self.bus]
        args += [f"w{2 if value is None else 3}@0x{address:02x}", f"0x{register >> 8:02x}", f"0x{register & 255:02x}"]
        if value is not None:
            args.append(f"0x{value:02x}")
        if count:
            args.append(f"r{count}")
        result = command(*args, capture=True)
        return [int(x, 16) for x in result.stdout.split()]

    def write(self, device, register, value):
        self.transfer(self.addresses[device], register, value=value)

    def steps(self, steps):
        for step in steps:
            if step["op"] == "sleep":
                time.sleep(step["seconds"])
                continue
            register = number(step["register"])
            value = number(step["value"])
            if step["op"] == "update":
                mask = number(step["mask"])
                current = self.transfer(self.addresses[step["device"]], register, count=1)[0]
                value = (current & ~mask) | (value & mask)
            self.write(step["device"], register, value)
            if "verify_mask" in step:
                mask = number(step["verify_mask"])
                observed = self.transfer(self.addresses[step["device"]], register, count=1)[0]
                if (observed & mask) != (value & mask):
                    raise RuntimeError(f"Register 0x{register:04x}: {step['description']}; "
                                       f"read 0x{observed:02x}, expected bits 0x{value & mask:02x}")
                print(f"0x{register:04x}: {step['description']} (0x{observed:02x})")


RATE_REGISTERS = {"a": 0x0001, "b": 0x0004}
LOCK_REGISTERS = {"a": 0x0013, "b": 0x5009}


def select_local(bus, link):
    """Select physical link(s) without assuming the remote serializer is reachable."""
    bit = {"a": 1, "b": 2, "ab": 3}[link]
    bus.steps([{"op": "update", "device": "deserializer", "register": "0x0f00", "mask": "0x03", "value": f"0x{bit:02x}"},
               {"op": "update", "device": "deserializer", "register": "0x0010", "mask": "0x33", "value": f"0x{0x30 | bit:02x}"},
               {"op": "update", "device": "deserializer", "register": "0x0012", "mask": "0x20", "value": "0x20"},
               {"op": "sleep", "seconds": 0.2}])


def read_serializer_id(bus, data):
    expected = [number(x) for x in data["serializer_id"]]
    try:
        observed = bus.transfer(bus.addresses["serializer"], 0x000d, count=len(expected))
    except subprocess.CalledProcessError:
        return None
    return observed if observed == expected else None


def select(bus, link, data):
    select_local(bus, link)
    if link != "ab" and read_serializer_id(bus, data) is None:
        raise RuntimeError(
            f"Link {link.upper()}: serializer is not reachable at "
            f"0x{bus.addresses['serializer']:02x}"
        )


def split_link_init(data, link):
    """Return (non-rate steps, desired rate code) for one physical link."""
    rate_register = RATE_REGISTERS[link]
    desired_rate = None
    steps = []
    for step in data["links"][link]["init"]:
        if (step["device"] == "deserializer"
                and number(step["register"]) == rate_register
                and number(step["mask"]) & 0x03 == 0x03):
            desired_rate = number(step["value"]) & 0x03
            continue
        steps.append(step)
    return steps, desired_rate


def wait_link_lock(bus, link, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if bus.transfer(bus.addresses["deserializer"],
                            LOCK_REGISTERS[link], count=1)[0] & 0x08:
                return True
        except subprocess.CalledProcessError:
            pass
        time.sleep(0.05)
    return False



def recover_serializer_rate(bus, link, data):
    """Recover reverse I2C by trying the supported DES RX rates after cold boot."""
    des_rate_reg = RATE_REGISTERS[link]
    current = bus.transfer(bus.addresses["deserializer"], des_rate_reg, count=1)[0]
    current_rate = current & 0x03

    candidates = []
    for rate in (current_rate, 1, 2):
        if rate in (1, 2) and rate not in candidates:
            candidates.append(rate)

    for rate in candidates:
        reg = bus.transfer(bus.addresses["deserializer"], des_rate_reg, count=1)[0]
        bus.transfer(
            bus.addresses["deserializer"], des_rate_reg,
            value=(reg & ~0x03) | rate,
        )

        reset_reg = 0x0010 if link == "a" else 0x0012
        reset_value = bus.transfer(
            bus.addresses["deserializer"], reset_reg, count=1
        )[0]
        bus.transfer(
            bus.addresses["deserializer"], reset_reg,
            value=reset_value | 0x20,
        )

        if not wait_link_lock(bus, link, timeout=1.0):
            print(
                f"Link {link.upper()}: no lock with DES RX rate "
                f"{rate * 3} Gbit/s"
            )
            continue

        time.sleep(0.05)
        if read_serializer_id(bus, data) is not None:
            print(
                f"Link {link.upper()}: recovered serializer at "
                f"{rate * 3} Gbit/s"
            )
            return rate

        print(
            f"Link {link.upper()}: lock but serializer not reachable at "
            f"{rate * 3} Gbit/s"
        )

    raise RuntimeError(
        f"Link {link.upper()}: serializer not reachable at either 3 or 6 Gbit/s"
    )


def sync_link_rate(bus, link, data, desired_rate):
    """Switch MAX96717 TX and matching MAX96716A RX rate without losing cold boot.

    The serializer must be changed while the old-rate link is still alive.
    Local deserializer access remains available after that write, so the matching
    RX rate can then be changed before a one-shot re-lock.
    """
    if desired_rate is None:
        return
    if desired_rate not in (1, 2):
        raise RuntimeError(f"Link {link.upper()}: unsupported GMSL2 rate code {desired_rate}")

    des_rate_reg = RATE_REGISTERS[link]
    ser_reg = bus.transfer(bus.addresses["serializer"], 0x0001, count=1)[0]
    des_reg = bus.transfer(bus.addresses["deserializer"], des_rate_reg, count=1)[0]
    ser_rate = (ser_reg >> 2) & 0x03
    des_rate = des_reg & 0x03

    if ser_rate == desired_rate and des_rate == desired_rate:
        print(f"Link {link.upper()}: GMSL2 rate already {desired_rate * 3} Gbit/s")
        return

    print(
        f"Link {link.upper()}: synchronise GMSL2 rate "
        f"SER={ser_rate} DES={des_rate} -> {desired_rate}"
    )

    # Change the remote transmitter first while reverse I2C is still usable.
    bus.transfer(
        bus.addresses["serializer"], 0x0001,
        value=(ser_reg & ~0x0c) | (desired_rate << 2),
    )

    # Then change the local receiver and force only this link to re-calibrate.
    bus.transfer(
        bus.addresses["deserializer"], des_rate_reg,
        value=(des_reg & ~0x03) | desired_rate,
    )
    reset_reg = 0x0010 if link == "a" else 0x0012
    reset_value = bus.transfer(bus.addresses["deserializer"], reset_reg, count=1)[0]
    bus.transfer(bus.addresses["deserializer"], reset_reg, value=reset_value | 0x20)

    if not wait_link_lock(bus, link):
        raise RuntimeError(
            f"Link {link.upper()}: did not lock after switching to "
            f"{desired_rate * 3} Gbit/s"
        )

    expected = [number(x) for x in data["serializer_id"]]
    observed = bus.transfer(bus.addresses["serializer"], 0x000d, count=len(expected))
    if observed != expected:
        raise RuntimeError(
            f"Link {link.upper()}: serializer unreachable after rate switch; "
            f"ID {observed}, expected {expected}"
        )

    ser_after = bus.transfer(bus.addresses["serializer"], 0x0001, count=1)[0]
    des_after = bus.transfer(bus.addresses["deserializer"], des_rate_reg, count=1)[0]
    if ((ser_after >> 2) & 0x03) != desired_rate or (des_after & 0x03) != desired_rate:
        raise RuntimeError(
            f"Link {link.upper()}: GMSL2 rate readback mismatch "
            f"SER={((ser_after >> 2) & 3)} DES={(des_after & 3)}"
        )
    print(f"Link {link.upper()}: GMSL2 rate {desired_rate * 3} Gbit/s locked")


def aliases(bus, link, data):
    info = data["links"][link]
    sensor = data["sensor"]
    for register, value in ((0x0042, number(info["sensor_alias"]) << 1),
                            (0x0043, number(sensor["address"]) << 1),
                            (0x0044, number(info["focus_alias"]) << 1),
                            (0x0045, number(sensor["focus_address"]) << 1)):
        bus.write("serializer", register, value)
    time.sleep(0.1)
    expected = [number(x) for x in sensor["id_values"]]
    actual = bus.transfer(number(info["sensor_alias"]), number(sensor["id_register"]), count=len(expected))
    if actual != expected:
        raise RuntimeError(f"Link {link.upper()}: sensor ID {actual}, expected {expected}")
    command("i2ctransfer", "-f", "-y", bus.bus, f"w1@{info['focus_alias']}",
            sensor["focus_status_register"], "r1", capture=True)
    print(f"Link {link.upper()}: verified {sensor['name']} at {info['sensor_alias']}")


def post_reset(bus, data, links):
    for link in links:
        bus.steps(data["links"][link]["post_reset"])


def run_init(bus, data, links):
    for link in links:
        bus.steps(data["pipeline"]["init"])

        # Apply local transport/tunnel settings first, but defer the forward
        # link-rate write. On a cold boot the MAX96717 can still be at its strap
        # rate; changing only the MAX96716A RX rate here would make 0x40 vanish.
        init_steps, desired_rate = split_link_init(data, link)
        bus.steps(init_steps)

        # Select locally first. If cold boot left SER and DES at different
        # rates, try 3G/6G on the DES until reverse I2C to 0x40 is recovered.
        # Only then switch both ends to the profile rate.
        select_local(bus, link)
        recover_serializer_rate(bus, link, data)
        sync_link_rate(bus, link, data, desired_rate)

        bus.steps(data["pipeline"]["sensor_power"])
        aliases(bus, link, data)
    if len(links) == 2:
        select(bus, "ab", data)
    post_reset(bus, data, links)


def run_pipeline(bus, data, links):
    for link in links:
        select(bus, link, data)
        bus.steps(data["pipeline"]["serializer_csi"])
        bus.steps(data["pipeline"]["deserializer_" + link])
    bus.steps(data["pipeline"]["route_ab" if len(links) == 2 else "route_a"])
    if len(links) == 2:
        select(bus, "ab", data)
    post_reset(bus, data, links)


def install_overlays(data, load=False):
    if load and command("dtoverlay", "-l", capture=True).stdout.strip():
        names = tuple(data["overlays"].values())
        if any(name in command("dtoverlay", "-l", capture=True).stdout for name in names):
            raise RuntimeError("Camera overlays are already loaded; run make unoverlay")
    directory = Path("/boot/firmware/overlays")
    for link in ("a", "b"):
        name = data["overlays"][link]
        command("dtc", "-@", "-H", "epapr", "-I", "dts", "-O", "dtb", "-o",
                str(directory / (name + ".dtbo")), str(ROOT / "overlays" / (name + ".dts")))
        if load:
            command("dtoverlay", name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("validate", "install-overlays", "init-a", "init-b", "init-a-b", "pipeline-a", "pipeline-a-b", "overlays-a-b"))
    parser.add_argument("--profile", default="imx708-revb")
    args = parser.parse_args()
    data = profile(args.profile)
    if args.action == "validate":
        print(f"Valid profile: {data['id']} ({data['sensor']['name']})")
        return
    if os.geteuid() != 0:
        parser.error("Hardware operations require sudo")
    if args.action in ("overlays-a-b", "install-overlays"):
        install_overlays(data, load=args.action == "overlays-a-b")
        return
    bus = Bus(data)
    links = ("a", "b") if args.action.endswith("a-b") else (args.action[-1],)
    if args.action.startswith("init"):
        run_init(bus, data, links)
    else:
        run_pipeline(bus, data, links)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
