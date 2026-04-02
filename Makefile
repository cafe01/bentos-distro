DISTRO_ROOT := $(shell pwd)
OUTPUT_ARM64 := $(DISTRO_ROOT)/output/arm64
OUTPUT_AMD64 := $(DISTRO_ROOT)/output/amd64

.PHONY: arm64 kernel-arm64 rootfs-arm64 amd64 kernel-amd64 rootfs-amd64 all clean

arm64: kernel-arm64 rootfs-arm64

kernel-arm64:
	@./scripts/build-kernel.sh --arch arm64 --output $(OUTPUT_ARM64)

rootfs-arm64: kernel-arm64
	@./scripts/build-rootfs.sh --arch arm64 --output $(OUTPUT_ARM64)

amd64: kernel-amd64 rootfs-amd64

kernel-amd64:
	@./scripts/build-kernel.sh --arch amd64 --output $(OUTPUT_AMD64)

rootfs-amd64: kernel-amd64
	@./scripts/build-rootfs.sh --arch amd64 --output $(OUTPUT_AMD64)

all: arm64 amd64

clean:
	rm -rf output/
