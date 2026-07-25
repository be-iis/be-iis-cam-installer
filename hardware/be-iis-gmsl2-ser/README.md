# BE-IIS-GMSL2-SER

The sensor head contains a MAX96717 serializer and an IMX708 camera.

| Device | Linux 7-bit address |
|---|---:|
| MAX96717 | `0x40` |
| IMX708 | `0x1a` |

The serializer accepts the IMX708 two-lane RAW10 stream and transports it
over a 6 Gbit/s GMSL2 link. The current profile uses tunnel mode.
