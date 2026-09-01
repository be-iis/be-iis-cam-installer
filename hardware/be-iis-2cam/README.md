# BE-IIS-2CAM

The BE-IIS-GMSL2-2CAM HAT uses a MAX96716A dual deserializer at `0x28` and
a TPL0102-100 digital potentiometer at `0x51`.

The validated configuration uses two camera links:

| Link | MAX96716A output | Raspberry Pi input |
| --- | --- | --- |
| A | Port A / DPHY0-1 | CSI1 |
| B | Port B / DPHY2-3 | CSI0 / J3 |

Initialize the links and video path with the manual workflow documented in the
repository root:

```bash
make unoverlay
make cameras-a-b
make a-b
```
