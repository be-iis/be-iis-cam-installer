SHELL := /bin/bash
.DEFAULT_GOAL := all-a

.PHONY: driver init-a init-b unoverlay remove-service all-a all status clean

# Build and install the patched IMX708 module. No camera configuration happens here.
driver:
	sudo bash tools/build-imx708-driver.sh

# Pure I2C control-plane bring-up for physical Link A, alias 0x52.
init-a:
	sudo bash tools/init-gmsl-link-a.sh

# Pure I2C control-plane bring-up for physical Link B, alias 0x53.
init-b:
	sudo bash tools/init-gmsl-link-b.sh

# Remove only BE-IIS dynamically loaded camera overlays.
unoverlay:
	sudo bash tools/remove-camera-overlays.sh

# Remove the formerly installed automatic init service from this Pi.
remove-service:
	sudo systemctl disable --now be-iis-camera-init.service 2>/dev/null || true
	sudo rm -f /etc/systemd/system/be-iis-camera-init.service
	sudo systemctl daemon-reload

# Explicit manual workflow. There is intentionally no systemd unit.
all-a: driver init-a

all: all-a

status:
	$(MAKE) -C drivers/imx708 status

clean:
	$(MAKE) -C drivers/imx708 clean
