SHELL := /bin/bash
.DEFAULT_GOAL := build

PREFIX ?= /usr/local
LIBEXEC_DIR ?= /usr/libexec/be-iis-camera
SYSTEMD_DIR ?= /etc/systemd/system

.PHONY: prepare fetch patch build install-driver install-userspace \
	configure remove-service install all status clean distclean

prepare fetch patch build clean distclean:
	$(MAKE) -C drivers/imx708 $@

install-driver:
	$(MAKE) -C drivers/imx708 install

install-userspace:
	sudo dtc -@ -H epapr -I dts -O dtb -o /boot/firmware/overlays/imx708-gmsl-link-a.dtbo overlays/imx708-gmsl-link-a.dts
	sudo install -D -m 0755 init-imx708-gmsl-port-a-tunnel.sh $(LIBEXEC_DIR)/init-link-a.sh
	sudo install -D -m 0644 tools/ina226/ina226-common.sh $(LIBEXEC_DIR)/ina226-common.sh
	sudo install -D -m 0755 tools/ina226/power-reset-camera.sh $(LIBEXEC_DIR)/power-reset-camera.sh
	sudo install -D -m 0755 tools/ina226/power-reset-link-a.sh $(LIBEXEC_DIR)/power-reset-link-a.sh
	sudo install -D -m 0755 tools/ina226/init-alerts.sh $(LIBEXEC_DIR)/ina226-init-alerts.sh
	sudo install -D -m 0755 tools/ina226/set-ocp.sh $(LIBEXEC_DIR)/set-ocp.sh
	sudo install -D -m 0755 tools/ina226/set-ovp.sh $(LIBEXEC_DIR)/set-ovp.sh
	sudo install -D -m 0755 tools/ina226/clear-alert.sh $(LIBEXEC_DIR)/clear-alert.sh
	sudo install -D -m 0755 tools/ina226/dump.sh $(LIBEXEC_DIR)/dump.sh
	sudo install -D -m 0755 tools/capture/capture-image.sh $(PREFIX)/bin/beiis-capture-image
	sudo install -D -m 0755 tools/capture/capture-video.sh $(PREFIX)/bin/beiis-capture-video
	sudo install -D -m 0644 tools/capture/capture-common.sh $(LIBEXEC_DIR)/capture-common.sh
	sudo install -D -m 0755 tools/gstreamer/preview.sh $(PREFIX)/bin/beiis-gst-preview
	sudo install -D -m 0755 tools/gstreamer/record.sh $(PREFIX)/bin/beiis-gst-record
	sudo install -D -m 0755 tools/raw/raw10-to-png.py $(PREFIX)/bin/beiis-raw10-to-png
	sudo ln -sfn $(LIBEXEC_DIR)/init-link-a.sh $(PREFIX)/bin/beiis-camera-init
	sudo ln -sfn $(LIBEXEC_DIR)/ina226-init-alerts.sh $(PREFIX)/bin/beiis-ina226-init-alerts
	sudo ln -sfn $(LIBEXEC_DIR)/set-ocp.sh $(PREFIX)/bin/beiis-ina226-set-ocp
	sudo ln -sfn $(LIBEXEC_DIR)/set-ovp.sh $(PREFIX)/bin/beiis-ina226-set-ovp
	sudo ln -sfn $(LIBEXEC_DIR)/clear-alert.sh $(PREFIX)/bin/beiis-ina226-clear-alert
	sudo ln -sfn $(LIBEXEC_DIR)/dump.sh $(PREFIX)/bin/beiis-ina226-dump

configure:
	sudo config/configure-boot.sh

# Remove the automatic camera initialisation from this Pi.
# The manual bring-up scripts remain available in the checkout.
remove-service:
	sudo systemctl disable --now be-iis-camera-init.service 2>/dev/null || true
	sudo rm -f $(SYSTEMD_DIR)/be-iis-camera-init.service
	sudo systemctl daemon-reload

install: install-driver install-userspace configure
	@echo
	@echo "Installation complete. Camera initialization is manual."
	@echo "Use sudo bash tools/bringup-serdes-links.sh first."

all: prepare fetch patch build install

status:
	$(MAKE) -C drivers/imx708 status
	@echo "Automatic camera initialization is intentionally disabled."

