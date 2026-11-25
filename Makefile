# cpz-arch — a minimal Arch Linux ARM experiment for the Cardputer Zero.
#
# Everything runs in a linux/arm64 container (Docker Desktop on Apple Silicon
# runs it natively). No loop devices, no privileged containers, no host root.
#
# The rootfs lives in a docker volume, not in the bind-mounted source tree:
# ownership and mode bits are not reliable on Docker Desktop's bind mounts, and
# they decide whether `sudo` is setuid and whether $HOME is usable. Only the
# finished image is copied back to ./out.
BUILDER_IMAGE ?= cpz-arch-builder
VOLUME        ?= cpz-arch-build

RUN = docker run --rm --platform linux/arm64 \
	-v "$(PWD):/work" -v "$(VOLUME):/build" \
	-e BUILD=/build -e OUT_DIR=/work/out -e UI_TEST="$(UI_TEST)" \
	-e UI_APPS_REPO_STABLE="$(UI_APPS_REPO_STABLE)" \
	-e UI_APPS_SIGLEVEL="$(UI_APPS_SIGLEVEL)" \
	-e UI_APPS_CATALOG_VERSION="$(UI_APPS_CATALOG_VERSION)" \
	-e UI_APPS_CATALOG_SHA256="$(UI_APPS_CATALOG_SHA256)" \
	-w /work $(BUILDER_IMAGE)

ifeq ($(UI_TEST),1)
UI_PACKAGE = ui-package
UI_TEST_STAGE = $(RUN) ./scripts/45-ui-test.sh
endif

NAME = cpz-arch-0.1.0-cm0

.PHONY: all builder rootfs image verify shell clean distclean help ui-package

all: image

help:
	@printf '%s\n' \
	  'make builder   build the arm64 builder image (Arch Linux ARM + mtools)' \
	  'make rootfs    install base + linux-rpi + vendor modules into the build volume' \
	  'make image     assemble the disk image (implies rootfs)' \
	  'make verify    check the image invariants without mounting it' \
	  'make verify UI_TEST=1  build and verify the UI hardware-test image' \
	  'make shell     interactive shell in the builder' \
	  'make clean     remove build artifacts and the build volume' \
	  'make distclean remove everything, including the builder image'

builder:
	docker build --platform linux/arm64 -t $(BUILDER_IMAGE) docker

ui-package: builder
	$(RUN) ./ui/build.sh stable

rootfs: builder $(UI_PACKAGE)
	$(RUN) ./scripts/10-rootfs.sh
	$(RUN) ./scripts/20-device.sh
	$(RUN) ./scripts/30-configure.sh
	$(RUN) ./scripts/35-ui-repo.sh
	$(UI_TEST_STAGE)

image: rootfs
	$(RUN) ./scripts/40-image.sh

verify: image
	$(RUN) ./scripts/50-verify.sh

shell: builder
	docker run --rm -it --platform linux/arm64 \
	  -v "$(PWD):/work" -v "$(VOLUME):/build" \
	  -e BUILD=/build -e OUT_DIR=/work/out -e UI_TEST="$(UI_TEST)" \
	  -e UI_APPS_REPO_STABLE="$(UI_APPS_REPO_STABLE)" \
	  -e UI_APPS_SIGLEVEL="$(UI_APPS_SIGLEVEL)" \
	  -e UI_APPS_CATALOG_VERSION="$(UI_APPS_CATALOG_VERSION)" \
	  -e UI_APPS_CATALOG_SHA256="$(UI_APPS_CATALOG_SHA256)" \
	  -w /work $(BUILDER_IMAGE) bash

clean:
	rm -rf out
	-docker volume rm -f $(VOLUME)

distclean: clean
	-docker image rm $(BUILDER_IMAGE)
