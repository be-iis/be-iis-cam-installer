#!/usr/bin/env python3
"""Calibrate the BE-IIS dual GMSL2 cameras for the stereo-distance demo.

The calibration board is held still for each capture. The cameras are acquired
one after the other, which is fine for this calibration workflow.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

import cv2
import numpy as np

WIDTH, HEIGHT = 1024, 576


def capture(camera: int, filename: pathlib.Path) -> None:
    command = [
        "rpicam-still", "--camera", str(camera), "--immediate", "--nopreview",
        "--width", str(WIDTH), "--height", str(HEIGHT), "--encoding", "png",
        "--timeout", "1000", "--output", str(filename),
    ]
    subprocess.run(command, check=True)


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
    args = parser.parse_args()

    try:
        cols, rows = (int(value) for value in args.corners.lower().split("x"))
    except ValueError:
        sys.exit("--corners must be formatted like 9x6")

    object_points = np.zeros((rows * cols, 3), np.float32)
    object_points[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    object_points *= args.square_mm / 1000.0  # calibration uses metres

    found_objects, corners0, corners1 = [], [], []
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1e-4)

    print("Stereo calibration")
    print(f"Chessboard: {cols}x{rows} inner corners, {args.square_mm:g} mm squares")
    print("Place the board in view of BOTH cameras. Use different distances,")
    print("heights and tilts. Avoid placing it only in the image centre.\n")

    with tempfile.TemporaryDirectory(prefix="beiis-stereo-") as temp:
        tempdir = pathlib.Path(temp)
        while len(found_objects) < args.pairs:
            index = len(found_objects) + 1
            input(f"[{index}/{args.pairs}] Position board and press Enter to capture...")
            image0 = tempdir / "camera0.png"
            image1 = tempdir / "camera1.png"
            try:
                capture(0, image0)
                capture(1, image1)
            except subprocess.CalledProcessError as error:
                print(f"Capture failed: {error}", file=sys.stderr)
                continue

            gray0 = cv2.imread(str(image0), cv2.IMREAD_GRAYSCALE)
            gray1 = cv2.imread(str(image1), cv2.IMREAD_GRAYSCALE)
            ok0, points0 = cv2.findChessboardCornersSB(gray0, (cols, rows))
            ok1, points1 = cv2.findChessboardCornersSB(gray1, (cols, rows))
            if not (ok0 and ok1):
                print("Chessboard was not found in both pictures; try again.")
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
    rect0, rect1, proj0, proj1, q, _, _ = cv2.stereoRectify(
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
