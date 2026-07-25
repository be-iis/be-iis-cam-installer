# BE-IIS-2CAM

The tested camera input uses MAX96716A Link A and CSI-2 Port A / DPHY0.

Key addresses:

| Device | Linux 7-bit address |
|---|---:|
| MAX96716A | `0x28` |
| TPL0102-100 | `0x51` |

The known-good output is two CSI-2 lanes on CAM/DISP1. Register
initialization is maintained in
`profiles/be-iis-2cam-imx708/init.sh`.
