# Installation

## Prerequisites

Use a Raspberry Pi kernel build tree matching `uname -r`. For the packaged
Raspberry Pi kernel this is normally provided by
`raspberrypi-kernel-headers`. A custom kernel must provide
`/lib/modules/$(uname -r)/build`.

Install the packages listed in the root README. Build the patched IMX708
module for the running kernel with:

```bash
make driver
```

No script configures the camera automatically at boot. For the validated
two-camera setup, use the manual sequence:

```bash
make unoverlay
make cameras-a-b
make a-b
```

See [Dual-camera manual bring-up](dual-camera-bringup.md) for the complete
procedure, including camera discovery. No target reboots the Pi.
