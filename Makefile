SHELL := /bin/bash
.DEFAULT_GOAL := help

CAMERA ?= 0
PROFILE ?= imx708-revb
CAPTURE_DIR ?= captures

.PHONY: help driver i2c-mux-driver \
	init-a init-b init-a-b \
	pipeline-a pipeline-a-b \
	overlays-a-b prepare-a-b unoverlay \
	png png-0 png-1 video video-0 video-1 video-dual \
	a a-b cameras-a-b all-a all status clean

help:
	@printf '%s\n' \
		'BE-IIS camera targets:' \
		'  make init-a          Initialise GMSL Link A control path' \
		'  make init-b          Initialise GMSL Link B control path' \
		'  make init-a-b        Initialise both GMSL control paths' \
		'  make pipeline-a      Configure Link A video pipeline' \
		'  make pipeline-a-b    Configure both video pipelines' \
		'  make prepare-a-b     Initialise both links and load selected camera overlays' \
		'  make prepare-a-b PROFILE=imx708-revb  Select a verified camera profile' \
		'  make unoverlay       Remove dynamically loaded BE-IIS camera overlays' \
		'' \
		'Capture / preview:' \
		'  make png CAMERA=0    Save a PNG from rpicam camera 0' \
		'  make png-0           Same for camera 0' \
		'  make png-1           Same for camera 1' \
		'  make video CAMERA=0  Live preview from camera 0' \
		'  make video-0         Live preview from camera 0' \
		'  make video-1         Live preview from camera 1' \
		'  make video-dual      Side-by-side HDMI preview of cameras 0 and 1'

# Build and install the patched IMX708 module. No camera configuration happens here.
driver:
	sudo bash tools/build-imx708-driver.sh

# Build and install the MAX96716A I2C mux module.
i2c-mux-driver:
	$(MAKE) -C drivers/max96716a-i2c-mux install

# Pure I2C control-plane bring-up for physical Link A, alias 0x52.
init-a:
	sudo python3 tools/camera_profile.py init-a --profile "$(PROFILE)"

# Pure I2C control-plane bring-up for physical Link B, alias 0x53.
init-b:
	sudo python3 tools/camera_profile.py init-b --profile "$(PROFILE)"

# Dual-link I2C control plane: sensor and focus aliases, no video pipeline.
init-a-b:
	sudo python3 tools/camera_profile.py init-a-b --profile "$(PROFILE)"

# Configure video for Link A only. This intentionally enables Pipe Y only.
pipeline-a:
	sudo python3 tools/camera_profile.py pipeline-a --profile "$(PROFILE)"

# Configure both video pipelines: A -> CSI1, B -> CSI0.
pipeline-a-b:
	sudo python3 tools/camera_profile.py pipeline-a-b --profile "$(PROFILE)"

# Compile and load two IMX708 overlays: Link A -> CSI1, Link B -> CSI0.
overlays-a-b:
	sudo python3 tools/camera_profile.py overlays-a-b --profile "$(PROFILE)"

# Prepare both cameras for Linux discovery. Video-pipeline setup is separate.
prepare-a-b: init-a-b overlays-a-b

# Remove only BE-IIS dynamically loaded camera overlays.
unoverlay:
	sudo bash tools/remove-camera-overlays.sh

# Capture one PNG from the selected rpicam camera index.
png:
	@case "$(CAMERA)" in 0|1) ;; *) echo 'CAMERA must be 0 or 1' >&2; exit 2 ;; esac
	@mkdir -p "$(CAPTURE_DIR)"
	@file="$(CAPTURE_DIR)/camera-$(CAMERA)-$$(date +%Y%m%d-%H%M%S).png"; \
		echo "Saving $$file"; \
		rpicam-still --camera "$(CAMERA)" --nopreview --timeout 1000 \
			--width 2304 --height 1296 --encoding png --output "$$file"

png-0:
	@$(MAKE) png CAMERA=0

png-1:
	@$(MAKE) png CAMERA=1

# Live DRM preview from one camera. Stop with Ctrl+C.
video:
	@case "$(CAMERA)" in 0|1) ;; *) echo 'CAMERA must be 0 or 1' >&2; exit 2 ;; esac
	rpicam-hello --camera "$(CAMERA)" --timeout 0 --width 2304 --height 1296

video-0:
	@$(MAKE) video CAMERA=0

video-1:
	@$(MAKE) video CAMERA=1

# Side-by-side HDMI preview of both cameras.
video-dual:
	python3 examples/dual-hdmi-preview/dual_preview.py --profile "$(PROFILE)"

# Compatibility aliases for the previous short names.
a: pipeline-a
	@echo 'NOTE: make a is deprecated; use make pipeline-a.'

a-b: pipeline-a-b
	@echo 'NOTE: make a-b is deprecated; use make pipeline-a-b.'

cameras-a-b: prepare-a-b
	@echo 'NOTE: make cameras-a-b is deprecated; use make prepare-a-b.'

# Legacy convenience targets. Not used by install.sh.
all-a: driver init-a
all: all-a

status:
	$(MAKE) -C drivers/imx708 status

clean:
	$(MAKE) -C drivers/imx708 clean
	$(MAKE) -C drivers/max96716a-i2c-mux clean
