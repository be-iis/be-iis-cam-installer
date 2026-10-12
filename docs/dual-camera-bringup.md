# Dual-camera manual bring-up

This is the verified manual workflow for two IMX708 GMSL2 camera heads on a
Raspberry Pi 5. It deliberately does not use systemd.

## Known mapping

| GMSL link | Sensor/focus aliases | MAX96716A output | Raspberry Pi input | rpicam index |
| --- | --- | --- | --- | --- |
| A | IMX708 0x52, DW9807 0x5c | Port A, DPHY0/1 | CSI1, 1f00128000.csi | 1 |
| B | IMX708 0x53, DW9807 0x5d | Port B, DPHY2/3 | CSI0 / J3, 1f00110000.csi | 0 |

The Device Tree overlays intentionally use separate Pi CSI receivers. Do not
move Link B from csi0 to csi1.

## Test a GMSL2 link before the camera is connected

Use the new `SENSOR=no` mode when you have a MAX96717 serializer connected
over coax, but **no image sensor** is installed yet. It verifies the
deserializer/serializer transport independently from sensor communication and
CSI-2 video.

1. Switch off the hardware; connect the serializer to the selected Link A or
   Link B using coax. Provide the correct power supplies for the Pi, HAT and
   serializer.
2. Start the Raspberry Pi 5 and ensure the HAT control interface is available
   at `/dev/i2c-11`. The installer must already be installed, or follow the
   [installation instructions](../README.md).
3. Run the command for your actual configuration from the repository:

~~~bash
make init-a SENSOR=no PROFILE=imx708-revb
# or:
make init-b SENSOR=no PROFILE=imx708-revb
# or, with two serializers:
make init-a-b SENSOR=no PROFILE=imx708-revb
~~~

Only use `make init-a-b` if **both** serializers are connected. These
commands do not load camera overlays or configure a CSI video pipeline.
In this mode the runner skips sensor-specific power/reset operations, I2C
aliases and sensor/focus identity checks. It still performs link configuration,
automatic rate recovery, MAX96717 detection, receiver adaptation and a final
MAX96716A LOCK check.

Example from an actual **Rev. B** test with no sensor:

~~~text
Link B: no lock with DES RX rate 3 Gbit/s
Link B: recovered serializer at 6 Gbit/s
Link B: GMSL2 rate already 6 Gbit/s
0x1503: Enable MAX96716A receiver adaptation ... (0x8a)
Link B: LOCKED (sensor check skipped)
~~~

The initial 3 Gbit/s message is not a failure if the link subsequently locks
at 6 Gbit/s. `LOCKED` and an exit status of 0 prove only the GMSL2 transport
connection; they do **not** prove sensor access, correct CSI routing or video
capture. If the final LOCK check fails, the command returns an error.

For independent register diagnostics, the MAX96716A is at I2C address
`0x28` on Raspberry Pi bus 11. The runner uses register `0x0013` for
Link A and `0x5009` for Link B; **bit 3 (`0x08`)** indicates LOCK:

~~~bash
sudo i2ctransfer -f -y 11 w2@0x28 0x00 0x13 r1  # Link A
sudo i2ctransfer -f -y 11 w2@0x28 0x50 0x09 r1  # Link B
~~~

Use these reads on the documented setup and only when the corresponding
device is not claimed by another driver. The successful Rev. B test produced
`0xda` for Link A, where bit 3 is set.

**Compatibility limit:** This camera-free test has been performed on the
**Rev. B** HAT with profile `imx708-revb`. Rev. A differs and has not been
validated with this profile. When connecting a new imager, provide its own
sensor-specific profile and switch back to the default `SENSOR=yes` mode;
`SENSOR=no` does not initialize any sensor. The detailed
[BE-IIS imager integration guide](https://be-iis.eu/wiki/gmsl2-2cam/bring-up/#new-imager)
describes the subsequent sensor, Device Tree and MIPI-CSI-2 work.

## Start from a clean dynamic-overlay state

~~~bash
cd ~/be-iis-cam-installer
make unoverlay
make prepare-a-b PROFILE=imx708-revb
make pipeline-a-b PROFILE=imx708-revb
~~~

The targets do the following:

- unoverlay removes only the two dynamically loaded BE-IIS overlays.
- prepare-a-b initializes both reverse-I2C paths using the selected JSON profile,
  creates aliases, then compiles and loads both IMX708 overlays.
- pipeline-a-b applies the profile's serializer and MAX96716A CSI sequences.

The previous `cameras-a-b` and `a-b` targets remain compatible aliases.

The profile enables MAX96716A receiver adaptation (`AdaptEn`, bit 7)
for each selected link: register `0x1403` for A and `0x1503` for B. Video
configuration reapplies it after its link resets. The helper preserves the other
register bits and prints the old and read-back values; a missing enable bit
fails the command. Link rate and EOM settings are unchanged. This setting is
reapplied on each initialization, not stored in nonvolatile memory.

Check discovery and each stream:

~~~bash
rpicam-hello --list-cameras
rpicam-hello --camera 0 -t 0 --width 2304 --height 1296
rpicam-hello --camera 1 -t 0 --width 2304 --height 1296
~~~

Stop each preview with Ctrl-C before testing the other camera.

## The important dual-pipe setting

Both IMX708 sensors send CSI stream 0. The MAX96716A must therefore use:

~~~text
0x0161 = 0x20   Pipe Y <- Link-A stream 0; Pipe Z <- Link-B stream 0
0x0160 = 0x03   enable Pipe Y and Pipe Z
~~~

The former 0x0161 = 0x32 selected stream 2. In that state, Linux can still talk
to the sensor and the sensor may be streaming, but the Pi receives no frames
and reports a camera frontend timeout.

## Known video format

The tested mode is 2304x1296, packed RAW10, two CSI-2 lanes at 900 Mbit/s per
lane. The media graph shows SBGGR10_1X10 at the CFE input; the Pi CFE then
uses an internal SBGGR16_1X16 representation. That conversion is normal.

For compact, machine-oriented facts and diagnosis, see
[AI dual-camera reference](ai-dual-camera-reference.md).
