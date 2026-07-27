# Link B / CSI1 bring-up notes

This note records the current state of the second BE-IIS GMSL2 camera input.
It is intentionally separate from the known-good Link-A configuration.

## Architecture

```text
IMX708 (0x1a)
  -> MAX96717F (0x40)
  -> GMSL2 Link B, coax, 6Gbit/s
  -> MAX96716A (0x28)
  -> Raspberry Pi 5 CSI1
```

The Raspberry Pi control I2C bus remains `/dev/i2c-11`, connected to the
CSI0-side I2C controller. CSI1 has no separate physical I2C connection.
The desired integration model is manual I2C configuration of serializer and
deserializer plus an IMX708-only Device Tree node on CSI1.

## Confirmed electrical and sensor path

- MAX96716A Link-B status `0x5009 = 0xc8`: Link B is locked.
- Remote serializer ID/revision at `0x40`: `0xbf 0x06` (MAX96717F).
- IMX708 chip ID at `0x1a`, register `0x0016`: `0x07 0x08`.
- During a libcamera capture attempt, IMX708 `0x0100 = 0x01`: the sensor
  is commanded to stream.
- MAX96717F Video TX2 for hardware pipe 2, `0x0112 = 0x8a`: bit 7
  (`PCLKDET`) is set. The serializer sees IMX708 pixel clock.

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

## Link-A baseline retained for Link B

The known-good Link-A procedure is the reference for serializer/deserializer
video configuration. Its relevant values must be retained for the Link-B
experiment:

| Device | Register | Required value | Note |
|---|---:|---:|---|
| MAX96717F | `0x005b` | `0x00` | CSI stream selection for serializer hardware pipe 2 |
| MAX96716A | `0x0161` | `0x20` | Link-B pipe selection in the existing procedure |

An intermediate test using `0x005b = 0x02` and `0x0161 = 0x30` did not
produce video lock. Those values are not part of the current procedure and
were restored to `0x00` and `0x20`.

## Current blocker

The pipeline is proven through the sensor input of the serializer, but not
through the GMSL video output:

| Observation | Value |
|---|---:|
| MAX96716A Link-B video lock, `0x023c` | `0x00` |
| `rpicam-still` on CSI1 | RP1-CFE timeout; no frame received |

Thus the remaining fault is between MAX96717 video transmission and MAX96716A
Link-B video reception/routing. It is not an IMX708 I2C, power/reset, sensor
streaming, or CSI1 Device Tree enumeration problem.

No production Link-B init sequence is claimed yet. Further changes must be
compared register-for-register against the working Link-A procedure before
they are applied.

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
