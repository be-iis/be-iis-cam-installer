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

## Start from a clean dynamic-overlay state

~~~bash
cd ~/be-iis-cam-installer
make unoverlay
make cameras-a-b
make a-b
~~~

The targets do the following:

- unoverlay removes only the two dynamically loaded BE-IIS overlays.
- cameras-a-b initializes both reverse-I2C paths, creates the aliases, compiles
  and loads both IMX708 overlays.
- a-b configures both serializers and both MAX96716A CSI outputs.

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
