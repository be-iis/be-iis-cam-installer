# BE-IIS GMSL2 IMX708 bring-up

This guide covers the validated Link-A diagnostic setup of the BE-IIS GMSL2
2CAM HAT with Raspberry Pi 5, MAX96716A, MAX96717F and IMX708.

## Update the checkout

Keep local experimental changes before updating:

```bash
git stash push -m "local camera tuning" -- init-imx708-gmsl-port-a-tunnel.sh
git pull --ff-only
```

Do not re-apply that stash when it only contains an old hard-coded DigiPot
value. The current init script accepts the desired value with `POT_B`.

## Link-A DigiPot setting

The GMSL2 link needs a different DigiPot channel-B value for the two tested
IMX708 modes. There is no common error-free value.

| IMX708 mode | DigiPot B |
| --- | --- |
| 2304 x 1296 | `0xba` |
| 4608 x 2592 | `0xb0` |

The values are also stored in
[`config/be-iis-2cam-imx708-link-a.conf`](../config/be-iis-2cam-imx708-link-a.conf).

Initialize Link A with the value for the intended mode:

```bash
# 2304 x 1296
sudo env POT_B=0xba bash ./init-imx708-gmsl-port-a-tunnel.sh init

# 4608 x 2592
sudo env POT_B=0xb0 bash ./init-imx708-gmsl-port-a-tunnel.sh init
```

`bash` is explicit here so the command also works if the executable bit of
the script has not been preserved by a checkout.

The init output must show the selected DigiPot value and a reachable
MAX96717. A setting outside the mode-specific optimum can cause coloured
pixel rows or horizontal artefacts in the recorded image.

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
