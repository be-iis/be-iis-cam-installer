obj-m += beiis_max96716a_i2c_mux.o

KDIR ?= /lib/modules/$(shell uname -r)/build
MODULE := beiis_max96716a_i2c_mux.ko
INSTALL_DIR := /lib/modules/$(shell uname -r)/updates

.PHONY: all install clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

install: all
	sudo install -D -m 0644 "$(MODULE)" "$(INSTALL_DIR)/$(MODULE)"
	sudo depmod "$(shell uname -r)"

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
