#!/usr/bin/env python3
"""Convert one tightly packed MIPI RAW10 frame to a viewable PNG."""

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=2304)
    parser.add_argument("--height", type=int, default=1296)
    parser.add_argument(
        "--bayer",
        choices=("RGGB", "BGGR", "GRBG", "GBRG"),
        default="BGGR",
    )
    parser.add_argument("--frame", type=int, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        import cv2
        import numpy as np
    except ImportError as error:
        raise SystemExit(
            "python3-numpy and python3-opencv are required"
        ) from error

    def unpack_raw10(packed: np.ndarray) -> np.ndarray:
        groups = packed.reshape(-1, 5)
        raw = np.empty(groups.shape[0] * 4, dtype=np.uint16)
        high = groups[:, :4].astype(np.uint16) << 2
        low = groups[:, 4].astype(np.uint16)
        raw[0::4] = high[:, 0] | (low & 0x03)
        raw[1::4] = high[:, 1] | ((low >> 2) & 0x03)
        raw[2::4] = high[:, 2] | ((low >> 4) & 0x03)
        raw[3::4] = high[:, 3] | ((low >> 6) & 0x03)
        return raw

    frame_size = args.width * args.height * 5 // 4
    offset = args.frame * frame_size

    with args.input.open("rb") as source:
        source.seek(offset)
        packed = np.frombuffer(source.read(frame_size), dtype=np.uint8)

    if packed.size != frame_size:
        raise SystemExit(
            f"frame {args.frame} has {packed.size} bytes; expected {frame_size}"
        )

    raw = unpack_raw10(packed).reshape(args.height, args.width)
    raw8 = np.right_shift(raw, 2).astype(np.uint8)
    conversion = getattr(cv2, f"COLOR_Bayer{args.bayer[:2]}2BGR")
    bgr = cv2.cvtColor(raw8, conversion)

    if not cv2.imwrite(str(args.output), bgr):
        raise SystemExit(f"failed to write {args.output}")

    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
