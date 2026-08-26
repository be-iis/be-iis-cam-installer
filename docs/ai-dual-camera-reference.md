# AI reference: dual IMX708 GMSL2 bring-up

Use this document as the factual baseline for later changes. Do not replace
verified register values with guesses.

## Verified topology

~~~text
Link A: IMX708 0x1a -> alias 0x52; DW9807 0x0c -> alias 0x5c
        MAX96716A Port A / DPHY0-1 -> Pi CSI1 (1f00128000.csi)
        libcamera / rpicam index 1

Link B: IMX708 0x1a -> alias 0x53; DW9807 0x0c -> alias 0x5d
        MAX96716A Port B / DPHY2-3 -> Pi CSI0 / J3 (1f00110000.csi)
        libcamera / rpicam index 0
~~~

Both sensors use RAW10, 2 lanes, 2304x1296 and CSI stream 0.

## Required MAX96716A routing

~~~text
0x0161 = 0x20:
  Pipe Y selection bits [2:0] = 0  => Link A stream 0
  Pipe Z selection bits [5:3] = 4  => Link B stream 0

0x0160 = 0x03:
  bit 0 = Pipe Y enabled
  bit 1 = Pipe Z enabled
~~~

Do not use 0x0161 = 0x32 for these IMX708 streams: it selects stream 2 and
causes a Pi frontend timeout without frame packets.

## Expected runtime evidence

~~~text
IMX708 0x0100 = 0x01       streaming enabled
MAX96717 0x0383 = 0x80     CSI input configured
MAX96717 0x0112 = 0x8a     PCLK detected while streaming
MAX96716A 0x0160 = 0x03    both pipes enabled
MAX96716A 0x0161 = 0x20    stream-0 routing
~~~

At the Pi:

- Link A media device bus info: platform:1f00128000.csi
- Link B media device bus info: platform:1f00110000.csi
- CFE input format: SBGGR10_1X10/2304x1296
- CFE internal format: SBGGR16_1X16/2304x1296 (normal expansion)

## Diagnostic interpretation

| Observation | Meaning / next check |
| --- | --- |
| IMX708 ID reads through alias | Reverse-I2C path is alive; it does not prove video packets. |
| 0x0100=1, serializer PCLKDET 0x8a, Pi timeout | Sensor and serializer input work. Check DeSer Pipe Y/Z selection and CSI output routing. |
| PCLKDET lacks bit 7 (0x0a) | Serializer does not detect the camera pixel clock. Check camera-side CSI input, clock/power/reset and cable. |
| Pi sees two cameras but a stream times out | Device Tree discovery is correct; inspect live MAX96716A routing, not the overlay first. |
| Lens dw9807 control I/O error | Check the corresponding focus alias (0x5c or 0x5d); this is separate from sensor frame routing. |

## Canonical commands

~~~bash
make unoverlay
make cameras-a-b
make a-b
rpicam-hello --camera 0 -t 0 --width 2304 --height 1296
rpicam-hello --camera 1 -t 0 --width 2304 --height 1296
~~~
