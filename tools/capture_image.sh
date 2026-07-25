#!/usr/bin/env bash
set -Eeuo pipefail


rm -f /tmp/direct-reference.jpg /tmp/direct-reference.dng

rpicam-still \
    --camera 0 \
    --nopreview \
    --mode 2304:1296:10:P \
    --shutter 10000 \
    --gain 1 \
    --raw \
    --timeout 3000 \
    --output /tmp/direct-reference.jpg

stat -c '%n: %s bytes' \
    /tmp/direct-reference.jpg \
    /tmp/direct-reference.dng