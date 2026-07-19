# Kernel patches

## `max96717-gpio-set-value.patch`

The Raspberry Pi MAX96717 GPIO `set` callback receives a requested value but
always writes the output-high bit. Consequently, a GPIO that has been set high
cannot subsequently be cleared through that callback.

This patch changes the register value to:

```c
value ? MAX96717_GPIO_OUT : 0
```

The patch was created by BE-IIS after reviewing the Raspberry Pi kernel driver.
It is a local workaround, not an accepted upstream Linux patch. Validate MFP3
and MFP4 on the target hardware before production use.
