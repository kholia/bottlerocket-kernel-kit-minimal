# Bottlerocket Kernel Kit
This is the kernel kit for [Bottlerocket](https://github.com/bottlerocket-os/bottlerocket).
It includes Linux kernels and dependencies for downstream package and variant builds.

## Contents
The kernel kit includes:
* multiple versions of the Linux kernel
* bootloaders
* firmware

### Availability
The [Bottlerocket kernel kit](https://gallery.ecr.aws/bottlerocket/bottlerocket-kernel-kit) is available through Amazon ECR Public.

### QEMU Kernel Smoke Test
On Ubuntu, install the runtime dependencies:
```shell
sudo apt update
sudo apt install --yes qemu-system-x86 busybox-static rpm2cpio cpio e2fsprogs make wget ca-certificates
```

On macOS ARM64, install QEMU and ext4 tooling, and keep Docker Desktop running
so the script can fetch a Linux static BusyBox when needed:
```shell
brew install qemu e2fsprogs wget
```

To boot the committed kernel 6.18 smoke-test RPM without rebuilding the kernel
package, run:
```shell
./tools/qemu-smoke-kernel-6.18.sh --no-build
```

The smoke test direct-boots the x86_64 kernel in QEMU with a minimal rootfs,
configures QEMU user-mode internet access, loads LKRG, and disables further
module loading. The guest includes BusyBox plus host `wget` for HTTPS fetches
when available. If `/dev/kvm` is not accessible, or when running from macOS
ARM64, the script falls back to QEMU TCG. Use `Ctrl-a x` to exit the
interactive QEMU session.

For an unattended smoke run that powers off after LKRG loads:
```shell
./tools/qemu-smoke-kernel-6.18.sh --no-build --append "console=ttyS0 earlyprintk=serial panic=0 root=/dev/vda ro rootfstype=ext4 rootwait init=/init smoke_poweroff=1"
```

Add `smoke_check_internet=1` to `--append` when you want the guest to verify
outbound HTTP through QEMU before powering off.

### Development
The kernel kit can be built on an **x86_64**, **aarch64**, or **macOS ARM64**
host. macOS builds require Docker Desktop and a Rust nightly toolchain so
Twoliter can be installed from source:
```shell
rustup toolchain install nightly
```

To build for the current host architecture, run:
```shell
make
```
OR
```shell
make ARCH=<aarch64, x86_64>
```
See the [BUILDING](BUILDING.md) guide for more details.
