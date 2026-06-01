# kernel-6.18

This package contains the Bottlerocket Linux kernel of the 6.18 series.

## Configuration Structure

The kernel configuration is organized into layered fragments:

* [`config-minimal-bottlerocket`](config-minimal-bottlerocket) - Minimal baseline borrowed from `~/repos/minimal-kernel-configs`; used to prune the Amazon Linux defaults before Bottlerocket support is restored
* [`config-bottlerocket`](config-bottlerocket) - Common Bottlerocket host support shared across all architectures
* [`config-bottlerocket-aarch64`](config-bottlerocket-aarch64) - ARM64-specific boot support
* [`config-bottlerocket-x86_64`](config-bottlerocket-x86_64) - x86_64-specific boot support
* [`config-bottlerocket-hardening`](config-bottlerocket-hardening) - Final hard exclusions that must remain disabled
* [`config-bottlerocket-lkrg`](config-bottlerocket-lkrg) - Optional LKRG fragment that enables the minimal module loader surface required for LKRG

During the build process, these configurations are merged in the following order:

1. Base Amazon Linux config (`../config-<arch>`)
2. Minimal Bottlerocket baseline (`config-minimal-bottlerocket`)
3. Microcode config (x86_64 only)
4. Architecture-specific Bottlerocket config (`config-bottlerocket-<arch>`)
5. Common Bottlerocket config (`config-bottlerocket`)
6. Hardening exclusions (`config-bottlerocket-hardening`)
7. Optional LKRG override (`config-bottlerocket-lkrg`) when `--with-lkrg` is used

By default, the 6.18 kernel is intentionally module-less: `CONFIG_MODULES` is
disabled, no runtime module loader is shipped, and any feature that is still
required must be built into the kernel image.  The optional LKRG mode enables
`CONFIG_MODULES` only to build and load the in-package LKRG module during boot;
LKRG mode also requires signed modules during that boot window.  The
`load-lkrg-module.service` unit disables further module loading immediately
after LKRG is loaded.  This still excludes kmod-based NVIDIA, EFA, and Neuron
packages from this kernel line.

The hardening layer keeps these interfaces off:

* Loadable modules and module-specific debug/signing options, except the signed LKRG-only path
* Network server filesystems, SMB/CIFS, IPsec/ESP, RXRPC, MPLS, and uncommon conntrack protocol helpers
* User namespaces and checkpoint/restore
* io_uring
* GPU/display stacks, including DRM, framebuffer, and simpledrm
* RDMA/EFA/MLX accelerator networking
* iSCSI initiator/target mode
* BPF preload sample infrastructure

Compatibility restores in `config-bottlerocket` require a specific Bottlerocket
host reason.  The current restore set is limited to boot and root filesystem
support, OCI container isolation, SELinux/seccomp/BPF enforcement, cgroup and
Kubernetes/ECS networking primitives, AWS/VMware/QEMU virtual devices, dm-verity,
and selected workload filesystems such as XFS, EXT4, NFS client, and CephFS.

The final merged configurations are written to:

* [`config-full-bottlerocket-aarch64-on-aarch64`](config-full-bottlerocket-aarch64-on-aarch64) - Complete ARM64 configuration for an ARM64 host
* [`config-full-bottlerocket-x86_64-on-aarch64`](config-full-bottlerocket-x86_64-on-aarch64) - Complete x86_64 configuration for an ARM64 host
* [`config-full-bottlerocket-aarch64-on-x86_64`](config-full-bottlerocket-aarch64-on-x86_64) - Complete ARM64 configuration for an X86_64 host
* [`config-full-bottlerocket-x86_64-on-x86_64`](config-full-bottlerocket-x86_64-on-x86_64) - Complete x86_64 configuration for an X86_64 host
* `config-full-bottlerocket-lkrg-*` - Complete configurations for the optional LKRG build

## Testing of Configuration Changes

Bottlerocket kernels are built in multiple flavors and for multiple
architectures.  The kernel configuration for any of those combinations might
change independently of the others.  Use
[`tools/latest-kernel-full-config.sh`](../../tools/latest-kernel-full-config.sh)
from the top-level repository to regenerate and validate full configs:

```
make full-config
```

To regenerate the optional LKRG config files:

```
make full-config-kernel-6.18-lkrg
```

The script also accepts `--with-lkrg` and `--without-lkrg` directly.

Any resulting diff to the generated `config-full-*` files should be included in
the package change for review.

Changes that can affect the resulting kernel configuration include:

* explicit kernel configuration changes in any source config fragment
* package updates or kernel rebases
* changes to Bottlerocket patches that add or remove Kconfig symbols
