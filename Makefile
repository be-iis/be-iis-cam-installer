SHELL := /bin/bash
.DEFAULT_GOAL := help

PROFILE ?= imx708-revb
SENSOR ?= yes
CAPTURE_DIR ?= captures

.PHONY: help driver init-a pipeline-a overlays-a prepare-a unoverlay \
	png png-0 video video-0 a all-a all status clean

help:
	@printf '%s\n' \
		'BE-IIS camera targets for Raspberry Pi 4 Model B:' \
		'  make prepare-a           Initialise Link A, configure video and load its overlay' \
		'  make init-a SENSOR=no    Verify GMSL2 LOCK with a serializer and no image sensor' \
		'  make unoverlay           Remove the dynamically loaded Link A overlay' \
		'  make png                 Save a PNG from camera 0' \
		'  make video               Live preview from camera 0'

# Build and install the patched IMX708 module.
driver:
	sudo bash tools/build-imx708-driver.sh

init-a:
	sudo python3 tools/camera_profile.py init-a --profile "$(PROFILE)" --sensor "$(SENSOR)"

pipeline-a:
	sudo python3 tools/camera_profile.py pipeline-a --profile "$(PROFILE)"

overlays-a:
	sudo python3 tools/camera_profile.py overlays-a --profile "$(PROFILE)"

# Finish all serializer I2C operations before the Linux camera driver probes.
prepare-a:
	sudo python3 tools/camera_profile.py prepare-a --profile "$(PROFILE)"

unoverlay:
	sudo bash tools/remove-camera-overlays.sh "$(PROFILE)"

png:
	@mkdir -p "$(CAPTURE_DIR)"
	@file="$(CAPTURE_DIR)/camera-0-$$(date +%Y%m%d-%H%M%S).png"; \
		echo "Saving $$file"; \
		rpicam-still --camera 0 --nopreview --timeout 1000 \
			--width 2304 --height 1296 --encoding png --output "$$file"

png-0: png

video:
	rpicam-hello --camera 0 --timeout 0 --width 2304 --height 1296

video-0: video

# Compatibility aliases for the existing single-camera targets.
a: pipeline-a
	@echo 'NOTE: make a is deprecated; use make pipeline-a.'

all-a: driver init-a
all: all-a

status:
	$(MAKE) -C drivers/imx708 status

clean:
	$(MAKE) -C drivers/imx708 clean
	$(MAKE) -C drivers/max96716a-i2c-mux clean
