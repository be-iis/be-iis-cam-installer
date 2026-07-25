#!/usr/bin/env bash
set -Eeuo pipefail


v4l2-ctl \
    --verbose \
    --device /dev/video0 \
    --set-fmt-video=width=2304,height=1296,pixelformat=pBAA \
    --stream-mmap=4 \
    --stream-count=3 \
    --stream-to=/tmp/stripe-test.raw