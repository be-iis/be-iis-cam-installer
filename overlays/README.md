# Device Tree overlay

The overlay is generated from
`profiles/max96716a-max96717-imx708-be-iis.json` with the official Analog
Devices `gen_gmsl_dts` generator. The build uses the bundled
`templates/imx708-be-iis.dtsi.in` camera template in a temporary copy of the
generator and does not modify the ADI source tree.

## Corrected MAX96717 pin assignment

The MAX96717 pinctrl binding requires a `pins` property. The camera template
therefore contains:

```dts
rclk-mfp2-state {
    function = "rclkout";
    pins = "mfp2";
};
```

Using `groups = "mfp2"` does not match the ADI binding. It can leave the
serializer reference clock on the wrong MFP and make acquisition of MFP4 as
the IMX708 XCLR GPIO fail with `-EREMOTEIO`.

The board profile uses:

- MFP2: 24 MHz IMX708 reference clock
- MFP3: camera supply enable
- MFP4: IMX708 XCLR
- MFP1: unchanged hardware LOCK output

All four IMX708 supply names point to the board's camera-enable regulator.

## Remote I2C aliases and focus actuator

The BE-IIS profile uses remote I2C aliases `0x52` and `0x53`. This avoids the
address collision previously caused by the `0x50` and `0x51` alias pool.

The DW9817 focus actuator is enabled by default in the BE-IIS profile. The
generated overlay connects the IMX708 through `lens-focus` and creates the
VCM at remote I2C address `0x0c`.

A profile for a fixed-focus camera or a camera without a compatible VCM can
disable autofocus support:

```json
"vcm_enabled": false
```

## Build and install

```bash
./build-install-overlay.sh \
    --adi-linux-dir "$HOME/src/adi-linux"
```

Build without installing:

```bash
./build-install-overlay.sh \
    --adi-linux-dir "$HOME/src/adi-linux" \
    --no-install
```

Generated files are written to `overlays/build/`.

Install this overlay in `config.txt`:

```ini
dtoverlay=max96716a-max96717-imx708-be-iis
```
