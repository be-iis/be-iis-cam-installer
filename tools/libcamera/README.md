# Raspberry Pi libcamera GMSL compatibility

## Purpose

The ADI MAX96716A driver exposes one media-controller source pad for each
CSI-2 PHY. Raspberry Pi libcamera 0.7.1 rejects bridge devices with more than
one source pad, even when only one source pad is connected to the CFE.

The ADI Linux branch also uses the upstream RP1-CFE driver. Its media entity
names use hyphens, while Raspberry Pi libcamera currently expects the legacy
downstream names that use underscores.

The included patch:

- traverses all source pads of a video bridge and keeps the first path that
  reaches the CFE;
- preserves the existing single-source behavior;
- supports both upstream and downstream RP1-CFE entity names;
- routes the upstream RP1-CFE image path through CSI-2 channel 0;
- disables embedded sensor metadata on the upstream CFE until stream-aware
  metadata routing is implemented;
- leaves the distro libcamera installation untouched by installing the patched
  build below `/usr/local`.

## Required topology

Use the upstream RP1-CFE driver with the ADI GMSL kernel. The generated overlay
must not replace the CFE compatible string with
`raspberrypi,rp1-cfe`.

Prepare the kernel module and the already generated overlay:

```bash
cd "$HOME/be-iis-cam-installer"

tools/libcamera/prepare_adi_upstream_cfe.sh \
    --adi-linux-dir "$HOME/src/adi-linux"
```

The script:

- builds and installs the upstream `rp1-cfe` module for the running kernel;
- removes only the downstream CFE compatible override from the generated
  BE-IIS overlay;
- rebuilds and installs the DTBO;
- creates timestamped backups before modifying or replacing files.

If more than one generated BE-IIS DTS exists, pass it explicitly:

```bash
tools/libcamera/prepare_adi_upstream_cfe.sh \
    --adi-linux-dir "$HOME/src/adi-linux" \
    --overlay-dts "$HOME/be-iis-cam-installer/overlays/build/max96716a-max96717-imx708-be-iis.dts"
```

## Build and install libcamera

Install the build dependencies:

```bash
sudo apt update
sudo apt install \
    build-essential git meson ninja-build pkg-config \
    python3-jinja2 python3-yaml python3-ply \
    libgnutls28-dev libssl-dev libudev-dev libyaml-dev \
    libdrm-dev libboost-dev libpisp-dev
```

Build the same Raspberry Pi libcamera version used by the tested Raspberry Pi
OS packages:

```bash
cd "$HOME/be-iis-cam-installer"

tools/libcamera/build_install_libcamera.sh
```

The build script applies both patches independently. It can therefore update an
existing source checkout that already contains the first GMSL topology patch.

The default source tag is `v0.7.1+rpt20260609`. Override it only when the
installed Raspberry Pi packages use another libcamera version:

```bash
tools/libcamera/build_install_libcamera.sh \
    --tag "v0.7.1+rpt20260609"
```

Reboot after preparing the upstream CFE and installing libcamera:

```bash
sudo reboot
```

## Verification

```bash
uname -r

cat /sys/bus/platform/devices/1f00128000.csi/modalias

lsmod | grep -E 'rp1.*cfe'

LIBCAMERA_LOG_LEVELS='*:DEBUG' \
    rpicam-hello --list-cameras
```

Expected CFE modalias:

```text
of:NcsiT(null)Craspberrypi,rp1-cfe-upstream
```

The loaded CFE module should be `rp1_cfe`, not
`rp1_cfe_downstream`.

## Remove the local libcamera build

```bash
tools/libcamera/uninstall_libcamera.sh
```

This removes only the files installed by the local Meson build. The Raspberry
Pi OS packages below `/usr` remain installed.

## Important

Running the main overlay installer again regenerates the DTS. Run
`prepare_adi_upstream_cfe.sh` again afterwards until the upstream CFE selection
is incorporated directly into the overlay generator.
