#!/usr/bin/env python3
"""Calibrate the BE-IIS dual GMSL2 cameras for the stereo-distance demo.

The calibration board is held still for each capture. The cameras are acquired
one after the other, which is fine for this calibration workflow.
"""
import argparse
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from camera_profile import load as load_camera_profile  # noqa: E402

import cv2
import numpy as np

WIDTH, HEIGHT = 1024, 576


def capture(camera: int, filename: pathlib.Path) -> None:
    subprocess.run([
        "rpicam-still", "--camera", str(camera), "--immediate", "--nopreview",
        "--width", str(WIDTH), "--height", str(HEIGHT), "--encoding", "png",
        "--timeout", "1000", "--output", str(filename),
    ], check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corners", default="9x6",
                        help="inner chessboard corners, e.g. 9x6")
    parser.add_argument("--square-mm", type=float, default=25.0,
                        help="printed chessboard square size in millimetres")
    parser.add_argument("--pairs", type=int, default=18,
                        help="number of successful image pairs to collect")
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path("stereo_calibration.npz"))
    parser.add_argument("--captures", type=pathlib.Path,
                        default=pathlib.Path("calibration-captures"),
                        help="directory that keeps every captured image pair")
    parser.add_argument("--profile", default="imx708-revb", help="verified camera profile")
    args = parser.parse_args()
    try:
        indices = load_camera_profile(args.profile)["capture"]["camera_indices"]
    except (OSError, ValueError, KeyError) as error:
        parser.error(f"invalid camera profile: {error}")

    try:
        cols, rows = (int(value) for value in args.corners.lower().split("x"))
    except ValueError:
        sys.exit("--corners must be formatted like 9x6")

    object_points = np.zeros((rows * cols, 3), np.float32)
    object_points[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    object_points *= args.square_mm / 1000.0  # calibration uses metres

    found_objects, corners0, corners1 = [], [], []
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1e-4)
    args.captures.mkdir(parents=True, exist_ok=True)

    print("Stereo calibration")
    print(f"Chessboard: {cols}x{rows} INNER corners, {args.square_mm:g} mm squares")
    print(f"Every image pair is retained in: {args.captures}/")
    print("Place the board in view of BOTH cameras. Use different distances,")
    print("heights and tilts. Avoid placing it only in the image centre.\n")

    attempt = 0
    while len(found_objects) < args.pairs:
        index = len(found_objects) + 1
        input(f"[{index}/{args.pairs}] Position board and press Enter to capture...")
        attempt += 1
        image0 = args.captures / f"{attempt:03d}-camera0.png"
        image1 = args.captures / f"{attempt:03d}-camera1.png"
        try:
            capture(indices[0], image0)
            capture(indices[1], image1)
        except subprocess.CalledProcessError as error:
            print(f"Capture failed: {error}", file=sys.stderr)
            continue

        gray0 = cv2.imread(str(image0), cv2.IMREAD_GRAYSCALE)
        gray1 = cv2.imread(str(image1), cv2.IMREAD_GRAYSCALE)
        ok0, points0 = cv2.findChessboardCornersSB(gray0, (cols, rows))
        ok1, points1 = cv2.findChessboardCornersSB(gray1, (cols, rows))
        if not (ok0 and ok1):
            absent = []
            if not ok0:
                absent.append("camera 0")
            if not ok1:
                absent.append("camera 1")
            print(f"Chessboard not found in {', '.join(absent)}; try again.")
            continue

        points0 = cv2.cornerSubPix(gray0, points0, (11, 11), (-1, -1), criteria)
        points1 = cv2.cornerSubPix(gray1, points1, (11, 11), (-1, -1), criteria)
        found_objects.append(object_points.copy())
        corners0.append(points0)
        corners1.append(points1)
        print("  accepted")

    _, matrix0, distortion0, _, _ = cv2.calibrateCamera(
        found_objects, corners0, (WIDTH, HEIGHT), None, None)
    _, matrix1, distortion1, _, _ = cv2.calibrateCamera(
        found_objects, corners1, (WIDTH, HEIGHT), None, None)
    rms, _, _, _, _, rotation, translation, _, _ = cv2.stereoCalibrate(
        found_objects, corners0, corners1, matrix0, distortion0, matrix1,
        distortion1, (WIDTH, HEIGHT), flags=cv2.CALIB_FIX_INTRINSIC,
        criteria=(cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 100, 1e-5))
    rect0, rect1, proj0, proj1, _, _, _ = cv2.stereoRectify(
        matrix0, distortion0, matrix1, distortion1, (WIDTH, HEIGHT),
        rotation, translation, flags=cv2.CALIB_ZERO_DISPARITY, alpha=0)
    map0x, map0y = cv2.initUndistortRectifyMap(
        matrix0, distortion0, rect0, proj0, (WIDTH, HEIGHT), cv2.CV_32FC1)
    map1x, map1y = cv2.initUndistortRectifyMap(
        matrix1, distortion1, rect1, proj1, (WIDTH, HEIGHT), cv2.CV_32FC1)

    baseline_m = abs(float(proj1[0, 3] / proj1[0, 0]))
    np.savez_compressed(args.output, map0x=map0x, map0y=map0y,
                        map1x=map1x, map1y=map1y,
                        focal_px=float(proj0[0, 0]), baseline_m=baseline_m,
                        rms=float(rms))
    print(f"\nSaved {args.output}")
    print(f"Stereo RMS: {rms:.3f} px; baseline: {baseline_m * 1000:.1f} mm")
    print("Repeat the calibration if RMS is above about 1 px.")


if __name__ == "__main__":
    main()
