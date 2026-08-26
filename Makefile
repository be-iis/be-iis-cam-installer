SHELL := /bin/bash
.DEFAULT_GOAL := all-a

.PHONY: driver i2c-mux-driver init-a init-b init-a-b video-a overlays-a-b cameras-a-b unoverlay remove-service all-a all status clean

# Build and install the patched IMX708 module. No camera configuration happens here.
driver:
	sudo bash tools/build-imx708-driver.sh

# Build and install only the MAX96716A I2C mux module.
# It creates virtual I2C buses for Link A and Link B; it is not a media driver.
i2c-mux-driver:
	$(MAKE) -C drivers/max96716a-i2c-mux install

# Pure I2C control-plane bring-up for physical Link A, alias 0x52.
init-a:
	sudo bash tools/init-gmsl-link-a.sh

# Pure I2C control-plane bring-up for physical Link B, alias 0x53.
init-b:
	sudo bash tools/init-gmsl-link-b.sh

# ADI-derived dual-link control-plane bring-up for sensor and focus aliases.
init-a-b:
	sudo bash tools/init-gmsl-links-a-b.sh

# Known Link-A video pipe: MAX96716A pipe 0 -> Port A / DPHY0 -> CSI1.
# Link B remains I2C-only.
video-a:
	sudo bash tools/configure-gmsl-link-a-video.sh

# Compile and load two IMX708 overlays: Link A -> CSI1, Link B -> CSI0.
overlays-a-b:
	sudo bash tools/load-dual-imx708-overlays.sh

# Full manual driver discovery sequence. No systemd is involved.
cameras-a-b: init-a-b overlays-a-b

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
	$(MAKE) -C drivers/max96716a-i2c-mux clean
