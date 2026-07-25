SHELL := /bin/bash
.DEFAULT_GOAL := build

KVER ?= $(shell uname -r)
KMAJOR := $(word 1,$(subst ., ,$(KVER)))
KMINOR := $(word 2,$(subst ., ,$(KVER)))

KERNEL_BRANCH ?= rpi-$(KMAJOR).$(KMINOR).y
KERNEL_BUILD ?= /lib/modules/$(KVER)/build
SOURCE_URL ?= https://raw.githubusercontent.com/raspberrypi/linux/$(KERNEL_BRANCH)/drivers/media/i2c/imx708.c

BUILD_DIR := $(CURDIR)/build/imx708
ORIGINAL_SOURCE := $(BUILD_DIR)/imx708.c.orig
PATCHED_SOURCE := $(BUILD_DIR)/imx708.c
MODULE := $(BUILD_DIR)/imx708.ko
PATCH_FILE := $(CURDIR)/patches/0001-imx708-increase-2304x1296-line-length.patch

PREPARED := $(BUILD_DIR)/.prepared
FETCHED := $(BUILD_DIR)/.fetched
PATCHED := $(BUILD_DIR)/.patched

.PHONY: prepare fetch patch build install all clean distclean status

prepare: $(PREPARED)

fetch: $(FETCHED)

patch: $(PATCHED)

build: $(MODULE)

all: install

$(PREPARED):
	@command -v curl >/dev/null || { echo "Error: curl is required"; exit 1; }
	@command -v make >/dev/null || { echo "Error: make is required"; exit 1; }
	@command -v patch >/dev/null || { echo "Error: patch is required"; exit 1; }
	@command -v gcc >/dev/null || { echo "Error: gcc is required"; exit 1; }
	@test -d "$(KERNEL_BUILD)" || { \
		echo "Error: kernel build directory not found: $(KERNEL_BUILD)"; \
		echo "Install the matching kernel headers first."; \
		exit 1; \
	}
	@test -f "$(KERNEL_BUILD)/Makefile" || { \
		echo "Error: kernel Makefile not found in $(KERNEL_BUILD)"; \
		exit 1; \
	}
	@mkdir -p "$(BUILD_DIR)"
	@touch "$@"
	@echo "Prepared for kernel $(KVER)"
	@echo "Kernel source branch: $(KERNEL_BRANCH)"

$(FETCHED): $(PREPARED)
	@echo "Fetching $(SOURCE_URL)"
	@curl -fL --retry 3 --output "$(ORIGINAL_SOURCE).tmp" "$(SOURCE_URL)"
	@mv "$(ORIGINAL_SOURCE).tmp" "$(ORIGINAL_SOURCE)"
	@cp "$(ORIGINAL_SOURCE)" "$(PATCHED_SOURCE)"
	@printf '%s\n' 'obj-m := imx708.o' > "$(BUILD_DIR)/Makefile"
	@rm -f "$(PATCHED)" "$(MODULE)"
	@touch "$@"
	@echo "Fetched original driver: $(ORIGINAL_SOURCE)"

$(PATCHED): $(FETCHED) $(PATCH_FILE)
	@cp "$(ORIGINAL_SOURCE)" "$(PATCHED_SOURCE)"
	@echo "Applying $(PATCH_FILE)"
	@patch --batch --forward -d "$(BUILD_DIR)" -p1 < "$(PATCH_FILE)"
	@grep -q '{0x0342, 0x20}' "$(PATCHED_SOURCE)"
	@grep -q '{0x0343, 0x00}' "$(PATCHED_SOURCE)"
	@grep -q 'line_length_pix = 0x2000' "$(PATCHED_SOURCE)"
	@touch "$@"
	@echo "Patched driver: $(PATCHED_SOURCE)"

$(MODULE): $(PATCHED)
	@echo "Building IMX708 module for $(KVER)"
	@$(MAKE) -C "$(KERNEL_BUILD)" M="$(BUILD_DIR)" modules
	@test -f "$@" || { echo "Error: module was not created: $@"; exit 1; }
	@echo "Built module: $@"

install: $(MODULE)
	@command -v sudo >/dev/null || { echo "Error: sudo is required"; exit 1; }
	@echo "Installing module for $(KVER)"
	sudo install -D -m 0644 "$(MODULE)" "/lib/modules/$(KVER)/updates/imx708.ko"
	sudo depmod "$(KVER)"
	@echo "Installed: /lib/modules/$(KVER)/updates/imx708.ko"
	@echo "Reboot or reload imx708 after unbinding all active camera devices."

status:
	@echo "Kernel version : $(KVER)"
	@echo "Kernel build   : $(KERNEL_BUILD)"
	@echo "Source branch  : $(KERNEL_BRANCH)"
	@echo "Source URL     : $(SOURCE_URL)"
	@echo "Patch          : $(PATCH_FILE)"
	@modinfo -n imx708 2>/dev/null || true

clean:
	@if test -d "$(BUILD_DIR)" && test -f "$(BUILD_DIR)/Makefile"; then \
		$(MAKE) -C "$(KERNEL_BUILD)" M="$(BUILD_DIR)" clean; \
	fi
	@rm -f "$(MODULE)"

distclean:
	@rm -rf "$(CURDIR)/build"
