# IMX708 horizontal-blanking driver patch

This package downloads the Raspberry Pi IMX708 driver matching the
major/minor version of the running kernel, applies a local patch, builds
the driver as an external kernel module, and installs it under the
kernel `updates` directory.

The patch changes only the 2304x1296 2x2-binned mode:

- `LINE_LENGTH_PCK`: `0x1e90` -> `0x2000`
- reported `line_length_pix`: `0x1e90` -> `0x2000`
- resulting HBLANK at 2304 pixels: `5888`

## Requirements

Install the build tools and headers matching the running kernel:

```bash
sudo apt install build-essential curl patch raspberrypi-kernel-headers
```

For a custom kernel, `/lib/modules/$(uname -r)/build` must point to its
prepared build tree.

## Individual steps

```bash
make prepare
make fetch
make patch
make
make install
```

`make` is equivalent to `make build`.

The complete workflow is:

```bash
make all
```

The default source branch is derived from the running kernel. For
example, kernel `6.13.x` selects Raspberry Pi branch `rpi-6.13.y`.
Override it when required:

```bash
make KERNEL_BRANCH=rpi-6.13.y all
```

## Inspect the result

```bash
git diff --no-index \
    build/imx708/imx708.c.orig \
    build/imx708/imx708.c

modinfo -n imx708
```

Installation does not reboot the system and does not unload an active
camera driver. Reboot explicitly after installation, or safely unbind
all camera devices before reloading the module.

## Cleanup

```bash
make clean
make distclean
```
