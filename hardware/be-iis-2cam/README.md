# BE-IIS-2CAM

The BE-IIS-GMSL2-2CAM Rev. B HAT uses a MAX96716A dual deserializer at
`0x28`. Rev. B has no TPL0102 digital potentiometer. The camera profile sets
both links to 6 Gbit/s, coax and tunnel mode through MAX96716A I2C registers.

The validated configuration uses two camera links:

| Link | MAX96716A output | Raspberry Pi input |
| --- | --- | --- |
| A | Port A / DPHY0-1 | CSI1 |
| B | Port B / DPHY2-3 | CSI0 / J3 |

Initialize the links and video path with the manual workflow documented in the
repository root:

```bash
make unoverlay
make prepare-a-b PROFILE=imx708-revb
make pipeline-a-b PROFILE=imx708-revb
```
