SHELL := /bin/bash
.DEFAULT_GOAL := all-a

.PHONY: driver i2c-mux-driver init-a init-b init-a-b a a-b overlays-a-b cameras-a-b unoverlay remove-service all-a all status clean

# Build and install the patched IMX708 module. No camera configuration happens here.
driver:
	sudo bash tools/build-imx708-driver.sh

# Build and install only the experimental MAX96716A I2C mux module.
# It creates virtual I2C buses; it is not a media driver and is not needed below.
i2c-mux-driver:
	$(MAKE) -C drivers/max96716a-i2c-mux install

# Pure I2C control-plane bring-up for physical Link A, alias 0x52.
init-a:
	sudo bash tools/init-gmsl-link-a.sh

# Pure I2C control-plane bring-up for physical Link B, alias 0x53.
init-b:
	sudo bash tools/init-gmsl-link-b.sh

# Dual-link I2C control plane: sensor and focus aliases, no video pipeline.
init-a-b:
	sudo bash tools/init-gmsl-links-a-b.sh

# Video for Link A only. This intentionally enables Pipe Y only.
a:
	sudo bash tools/bringup-gmsl-link-a.sh

# Verified dual-video configuration: A -> CSI1, B -> CSI0.
# Prerequisite: make cameras-a-b
a-b:
	sudo bash tools/bringup-gmsl-links-a-b.sh

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
