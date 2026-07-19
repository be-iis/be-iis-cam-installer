# Kernel module build scripts

The scripts download driver sources from the Raspberry Pi Linux branch that
matches the running kernel, build external modules and install them below:

```text
/lib/modules/$(uname -r)/updates/
```

## Scripts

- `imx708_mod_build.sh`: Sony IMX708 sensor driver
- `max96717_mod_build.sh`: Maxim MAX96717F serializer driver
- `max96714_mod_build.sh`: Maxim MAX96714F deserializer driver

Run a script individually, for example:

```bash
./max96717_mod_build.sh
```

Alternatively, run `install.sh` from the repository root to build everything.

The matching Raspberry Pi kernel headers/build tree must be available at:

```text
/lib/modules/$(uname -r)/build
```

The MAX96717 script applies the local fix documented in
[`patches/README.md`](patches/README.md).
