DISTRO_ROOT := $(shell pwd)
OUTPUT_ARM64 := $(DISTRO_ROOT)/output/arm64

.PHONY: arm64 kernel-arm64 rootfs-arm64 clean

arm64: kernel-arm64 rootfs-arm64

kernel-arm64:
	@./scripts/build-kernel.sh --output $(OUTPUT_ARM64)

rootfs-arm64: kernel-arm64
	@./scripts/build-rootfs.sh --output $(OUTPUT_ARM64)

clean:
	rm -rf output/
