ifneq (${KERNELRELEASE},)

# KERNELRELEASE defined: we are being compiled as part of the Kernel
obj-m := HFT_drivers.o

else

# We are being compiled as a module: use the Kernel build system

KERNEL_SOURCE := /usr/src/linux-headers-$(shell uname -r)
PWD := $(shell pwd)

default: module HFT_harness

module:
	${MAKE} -C ${KERNEL_SOURCE} SUBDIRS=${PWD} modules

HFT_harness: HFT_harness.c HFT_drivers.h
	gcc -O2 -Wall -Wextra -o HFT_harness HFT_harness.c

clean:
	${MAKE} -C ${KERNEL_SOURCE} SUBDIRS=${PWD} clean
	${RM} HFT_harness

endif 
