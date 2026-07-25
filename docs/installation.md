# Installation

## Prerequisites

Use a Raspberry Pi kernel build tree matching `uname -r`. For the packaged
Raspberry Pi kernel this is normally provided by
`raspberrypi-kernel-headers`. A custom kernel must provide
`/lib/modules/$(uname -r)/build`.

Install the packages listed in the root README, then run:

```bash
make all
```

The installer edits `config.txt` only when I2C is not already enabled. Before
an edit it creates a timestamped backup next to the file. It also installs:

- `/lib/modules/$(uname -r)/updates/imx708.ko`
- `/usr/libexec/be-iis-camera/init.sh`
- `/etc/systemd/system/be-iis-camera-init.service`
- `/etc/modules-load.d/be-iis-camera.conf`
- user commands under `/usr/local/bin`

No reboot is automatic.

## Service control

```bash
sudo systemctl start be-iis-camera-init.service
sudo systemctl restart be-iis-camera-init.service
sudo systemctl status be-iis-camera-init.service
journalctl -u be-iis-camera-init.service
```

## Unattended boot

The service is `Type=oneshot` and waits for `/dev/i2c-11`. It initializes the
GMSL2 chain once, applies the standard IMX708 overlay when needed, and
configures the direct RP1-CFE RAW path.
