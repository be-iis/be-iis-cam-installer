# Link B / CSI1 bring-up notes

This note records the validated electrical and I2C bring-up of the second
BE-IIS GMSL2 camera input. It is intentionally separate from the normal
Link-A configuration.

## Confirmed hardware path

```text
IMX708 (0x1a)
  -> MAX96717F (0x40)
  -> GMSL2 Link B, coax, 6Gbit/s
  -> MAX96716A (0x28), pipe 1 / PHY1
  -> Raspberry Pi 5 CSI1
```

The Raspberry Pi control I2C bus remains `/dev/i2c-11`, connected to the
CSI0-side I2C controller. CSI1 does not need a separate I2C connection.

## Validated on 2026-07-28

- Link-B lock register `MAX96716A 0x5009`: `0xc8`
  (bit 3, Link-B LOCK, set).
- Remote serializer ID/revision at `0x40`: `0xbf 0x06`
  (MAX96717F).
- IMX708 chip ID at `0x1a`, register `0x0016`: `0x07 0x08`.

The reliable sensor power/reset sequence is:

```bash
sudo i2ctransfer -f -y 11 w3@0x40 0x00 0x02 0x43
sudo i2ctransfer -f -y 11 w3@0x40 0x02 0xca 0x80
sudo i2ctransfer -f -y 11 w3@0x40 0x02 0xc7 0x80
sleep 0.2
sudo i2ctransfer -f -y 11 w3@0x40 0x02 0xc7 0x90
sleep 0.1
sudo i2ctransfer -f -y 11 w3@0x40 0x02 0xca 0x90
sleep 0.1
sudo i2ctransfer -f -y 11 w2@0x1a 0x00 0x16 r2
```

The first write enables MAX96717 pipe 0 before the camera power sequence.
Without it, the remote sensor I2C transaction can fail even when Link B is
locked and the serializer is reachable.

## MAX96716A state observed after Link-B bring-up

| Register | Value | Meaning |
|---|---:|---|
| `0x0160` | `0x03` | Pipes 0 and 1 enabled |
| `0x0161` | `0x32` | Pipe 1 assigned to Link B |
| `0x04b4` | `0x0f` | Link-B tunnel pipe enabled; PHY1 selected |
| `0x0313` | `0x02` | Global CSI output enabled |

This confirms that the deserializer pipe routing is already active. No
MAX96716A register writes are needed for the sensor-only CSI1 test.

## Sensor-only Device Tree overlay

`imx708-gmsl-link-b-csi1-overlay.dts` deliberately creates only the IMX708
node:

- sensor I2C node on `i2c_csi_dsi0` (the controller behind `/dev/i2c-11`);
- video endpoint on `csi1`;
- logical camera clock handle required by the IMX708 driver;
- all IMX708 supplies are dummy regulators, because MAX96717 controls camera
  power and reset over I2C;
- no MAX96716A or MAX96717 Device Tree node.

Compile it on the Pi:

```bash
cd ~/be-iis-cam-installer/overlays
mkdir -p build
dtc -@ -H epapr -I dts -O dtb \
  -o build/imx708-gmsl-link-b-csi1.dtbo \
  imx708-gmsl-link-b-csi1-overlay.dts
```

Load it only after the manual Link-B I2C bring-up has completed. The overlay is
for a live CSI1 test; it does not replace the production boot configuration.
