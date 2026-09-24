# BE-IIS GMSL2 IMX708 bring-up

This guide covers the BE-IIS GMSL2 2CAM Rev. B HAT with Raspberry Pi 5,
MAX96716A, MAX96717 and two IMX708 cameras.

## Update the checkout

Update the current branch while keeping any local experiments:

```bash
git pull --ff-only
```

## Rev. B link configuration

Rev. B has no TPL0102 DigiPot. The profile configures the MAX96716A over I2C:

| Link | Rate | Coax selection | Tunnel selection |
| --- | --- | --- | --- |
| A | `0x0001[1:0] = 2` (6 Gbit/s) | `0x0011[0] = 1` | `0x0474[0] = 1` |
| B | `0x0004[1:0] = 2` (6 Gbit/s) | `0x0011[2] = 1` | `0x04b4[0] = 1` |

Initialize both links and their CSI pipelines with the IMX708 profile:

```bash
make unoverlay
make prepare-a-b PROFILE=imx708-revb
make pipeline-a-b PROFILE=imx708-revb
```

The profile also verifies the remote IMX708 IDs and enables receiver adaptation
after link resets. The old mode-specific DigiPot values under `config/` are
retained only as a record for earlier hardware.

## Capture a still image

```bash
rpicam-still -n -t 1500 --width 2304 --height 1296 -o ~/link-a-2k.jpg
rpicam-still -n -t 1500 --width 4608 --height 2592 -o ~/link-a-4k.jpg
```

The image is stored in the home directory of the active user.

## Show live video on a display while connected through SSH

Connect HDMI to the Raspberry Pi and leave its local terminal visible. Start
the preview over SSH:

```bash
rpicam-hello -t 0 --width 2304 --height 1296
```

The camera preview is rendered through DRM/KMS on the locally attached
display; it is not shown in the SSH terminal. Stop it with `Ctrl+C` in the
SSH session. Use the matching 4K mode when required:

```bash
rpicam-hello -t 0 --width 4608 --height 2592
```

Do not use `-n` with `rpicam-hello` when a preview is wanted: it disables
the preview.
