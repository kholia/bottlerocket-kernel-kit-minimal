# tools/qemu-smoke-kernel-6.18.sh --no-build --no-config --no-kvm --append "console=ttyS0 earlyprintk=serial panic=0 root=/dev/vda ro rootfstype=ext4 rootwait init=/init smoke_poweroff=1"

TOP := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))
TOOLS_DIR := $(TOP)tools
TWOLITER_DIR := $(TOOLS_DIR)/twoliter
TWOLITER := $(TWOLITER_DIR)/twoliter
CARGO_HOME := $(TOP).cargo
KERNEL_CONFIG_SCRIPT := $(TOOLS_DIR)/latest-kernel-full-config.sh
TWOLITER_VERSION ?= "0.17.0"
TWOLITER_SHA256_AARCH64 ?= "474b6dce0ddd993e926065baee55c8a06167615cb2c0513c2c9f4f02876a7011"
TWOLITER_SHA256_X86_64 ?= "f7239b329ae71f75e5f3262e6b83c0a96bf36bfed1dda225fc3998316b5a92d9"
KIT ?= bottlerocket-kernel-kit
UNAME_ARCH = $(shell uname -m)
ifeq ($(UNAME_ARCH), arm64)
	HOST_ARCH = aarch64
else
	HOST_ARCH = $(UNAME_ARCH)
endif
ARCH ?= $(HOST_ARCH)
VENDOR ?= bottlerocket
SDK ?= ""
KERNEL_CONFIG_ARGS ?=

ifeq ($(HOST_ARCH), aarch64)
	TWOLITER_SHA256=$(TWOLITER_SHA256_AARCH64)
	SDK_PLATFORM ?= linux/arm64
else ifeq ($(HOST_ARCH), x86_64)
	TWOLITER_SHA256=$(TWOLITER_SHA256_X86_64)
	SDK_PLATFORM ?= linux/amd64
else
	TWOLITER_SHA256=$(TWOLITER_SHA256_X86_64)
endif


all: build

full-config:
	SDK=$(SDK) SDK_PLATFORM=$(SDK_PLATFORM) ./tools/docker-run.sh "/bottlerocket-kernel-kit/tools/latest-kernel-full-config.sh" $(KERNEL_CONFIG_ARGS)

full-config-kernel-6.18:
	SDK=$(SDK) SDK_PLATFORM=$(SDK_PLATFORM) ./tools/docker-run.sh "/bottlerocket-kernel-kit/tools/latest-kernel-full-config.sh" --kernel 6.18 $(KERNEL_CONFIG_ARGS)

full-config-kernel-6.18-lkrg:
	SDK=$(SDK) SDK_PLATFORM=$(SDK_PLATFORM) ./tools/docker-run.sh "/bottlerocket-kernel-kit/tools/latest-kernel-full-config.sh" --kernel 6.18 --with-lkrg

prep:
	@mkdir -p $(TWOLITER_DIR)
	@mkdir -p $(CARGO_HOME)
	@$(TOOLS_DIR)/install-twoliter.sh \
		--repo "https://github.com/bottlerocket-os/twoliter" \
		--version v$(TWOLITER_VERSION) \
		--directory $(TWOLITER_DIR) \
		--reuse-existing-install \
		--allow-binary-install $(TWOLITER_SHA256) \
		--allow-from-source

update: prep
	@$(TWOLITER) update

fetch: prep
	@$(TWOLITER) fetch --arch $(ARCH)

build: fetch
	@$(TWOLITER) build kit $(KIT) --arch $(ARCH)

publish: prep
	@$(TWOLITER) publish kit $(KIT) $(VENDOR)

TWOLITER_MAKE = $(TWOLITER) make --cargo-home $(CARGO_HOME) --arch $(ARCH)

# Treat any targets after "make twoliter" as arguments to "twoliter make".
ifeq (twoliter,$(firstword $(MAKECMDGOALS)))
  TWOLITER_MAKE_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(eval $(TWOLITER_MAKE_ARGS):;@:)
endif

# Transform "make twoliter" into "twoliter make", for access to tasks that are
# only available through the embedded Makefile.toml.
twoliter: prep
	@$(TWOLITER_MAKE) $(TWOLITER_MAKE_ARGS)

.PHONY: prep update fetch build publish twoliter full-config full-config-kernel-6.18 full-config-kernel-6.18-lkrg
