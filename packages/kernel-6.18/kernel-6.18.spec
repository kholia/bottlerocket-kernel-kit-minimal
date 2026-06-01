%global debug_package %{nil}
%global __strip /bin/true

%global kmajor 6.18
%global lkrg_version 1.0.1

%global host_arch %(uname -m)
%global _ko ko

%bcond_with lkrg

Name: %{_cross_os}kernel-%{kmajor}
Version: 6.18.30
Release: 1%{?dist}
Summary: The Linux kernel
License: GPL-2.0 WITH Linux-syscall-note
URL: https://www.kernel.org/
# Use latest-kernel-srpm-url.sh to get this.
Source0: https://cdn.amazonlinux.com/al2023/blobstore/f82452e4fddb3f26f08c0c3c3e731306f5f0baf2001fd7ac78f7b25d9689f528/kernel6.18-6.18.30-61.116.amzn2023.src.rpm
Source1: gpgkey-B21C50FA44A99720EAA72F7FE951904AD832C631.asc

# Custom Bottlerocket kernel configurations.
Source100: config-bottlerocket
Source101: config-bottlerocket-x86_64
Source102: config-bottlerocket-aarch64
Source103: config-minimal-bottlerocket
Source104: config-bottlerocket-hardening
Source105: config-bottlerocket-lkrg
# Fully generated kernel configurations used for validation.
Source110: config-full-bottlerocket-x86_64-on-aarch64
Source111: config-full-bottlerocket-aarch64-on-aarch64
Source112: config-full-bottlerocket-x86_64-on-x86_64
Source113: config-full-bottlerocket-aarch64-on-x86_64
# Fully generated kernel configurations for the optional LKRG build.
Source114: config-full-bottlerocket-lkrg-x86_64-on-aarch64
Source115: config-full-bottlerocket-lkrg-aarch64-on-aarch64
Source116: config-full-bottlerocket-lkrg-x86_64-on-x86_64
Source117: config-full-bottlerocket-lkrg-aarch64-on-x86_64

# Adjust kernel-devel mount behavior if not squashfs.
Source210: var-lib-kernel-devel-lower.mount.drop-in.conf.in

# Bootconfig snippets to adjust the default kernel command line for the platform.
Source300: bootconfig-aws.conf
Source301: bootconfig-vmware.conf

# Optional LKRG source and boot-time loader.
Source400: https://download.openwall.net/pub/projects/lkrg/lkrg-%{lkrg_version}.tar.gz
Source401: load-lkrg-module.service

# Enable INITRAMFS_FORCE config option for our use case.
Patch1003: 1003-initramfs-unlink-INITRAMFS_FORCE-from-CMDLINE_-EXTEN.patch
# Increase default of sysctl net.unix.max_dgram_qlen to 512.
Patch1004: 1004-af_unix-increase-default-max_dgram_qlen-to-512.patch
# Disable incomplete measurement into PCR 9 on aarch64.
Patch1006: 1006-efi-libstub-don-t-measure-kernel-command-line-into-P.patch

BuildRequires: bc
BuildRequires: elfutils-devel
BuildRequires: hostname
BuildRequires: openssl-devel

# CPU microcode updates are included as "extra firmware" so the files don't
# need to be installed on the root filesystem. However, we want the license and
# attribution files to be available in the usual place.
%if "%{_cross_arch}" == "x86_64"
BuildRequires: %{_cross_os}microcode-ec2
Requires: %{_cross_os}microcode-licenses
%endif

# No bare-metal for this kernel
Conflicts: %{_cross_os}variant-platform(metal)

# No squashfs support, rely on erofs for compression
Conflicts: %{_cross_os}image-feature(no-erofs-root-partition)

# No runtime kernel-devel support
Conflicts: %{_cross_os}image-feature(external-kmod-development)

# Legacy iptables support is not enabled in this kernel.
Conflicts: %{_cross_os}iptables-legacy

# FIPS certification is not yet available for this kernel.
Conflicts: %{_cross_os}image-feature(fips)

# This kernel only supports the optional in-package LKRG module. NVIDIA and
# similar kmod-based variants cannot use this minimal kernel package.
Conflicts: %{_cross_os}variant-flavor(nvidia)
Conflicts: %{_cross_os}variant-flavor(nvidia-fips)

# Pull in default mkfs conf for xfsprogs.
Requires: (%{name}-mkfs-xfs-conf if %{_cross_os}xfsprogs)

# Pull in platform-dependent boot config snippets.
Requires: (%{name}-bootconfig-aws if %{_cross_os}variant-platform(aws))
Requires: (%{name}-bootconfig-vmware if %{_cross_os}variant-platform(vmware))

%global _cross_ksrcdir %{_cross_usrsrc}/kernels/%{version}
%global _cross_kmoddir %{_cross_libdir}/modules/%{version}

%description
%{summary}.

%package devel
Summary: Configured Linux kernel source

%description devel
%{summary}.

%package bootconfig-aws
Summary: Boot config snippet for the Linux kernel on AWS

%description bootconfig-aws
%{summary}.

%package bootconfig-vmware
Summary: Boot config snippet for the Linux kernel on VMware

%description bootconfig-vmware
%{summary}.

%package mkfs-xfs-conf
Summary: mkfs configurations for the XFS filesystem

%description mkfs-xfs-conf
%{summary}.

%package headers
Summary: Header files for the Linux kernel for use by glibc

%description headers
%{summary}.

%prep
%if "%{_cross_arch}" == "aarch64"
%global _cross_kimage vmlinuz.efi
%endif

rpmkeys --import %{S:1} --dbpath "${PWD}/rpmdb"
rpmkeys --checksig %{S:0} --dbpath "${PWD}/rpmdb"
rm -rf "${PWD}/rpmdb"
rpm2cpio %{S:0} | cpio -iu {,./}linux-%{version}.tar.xz {,./}config-%{_cross_arch} {,./}"*.patch" {,./}kernel6.18.spec
tar -xof linux-%{version}.tar.xz; rm linux-%{version}.tar.xz
# Count all the patches extracted from the SRPM
patches_count=$(find -name "*.patch" | wc -l)
# Find patch ordering based on the Source0 kernel.spec file from the SRPM.
# First, find all `PatchNNN` lines. Then, sort by the patch number (-k1.6 in sort sets the 6th char
# in field 1 of input as the sort parameter). Finally, capture just the patch file name specified.
readarray -t patches < <(grep -P "^Patch\d+" kernel6.18.spec | sort -n -k1.6 | grep -oP "^Patch\d+: \K.*\.patch$" kernel6.18.spec)
# Fail the build if there is a mismatch in the number of patches found
if [[ "${patches_count}" -ne "${#patches[@]}" ]]; then
  echo "Mismatch on patches count!"
  exit 1
fi

%setup -TDn linux-%{version}
%if %{with lkrg}
tar -xof %{S:400} -C %{_builddir}
%endif
# Patches from the Source0 SRPM
for patch in ${patches[@]}; do
    patch -p1 <../"$patch"
done
# Patches listed in this spec (Patch0001...)
%autopatch -p1 -M 1999

%if "%{_cross_arch}" == "x86_64"
microcode="$(find %{_cross_libdir}/firmware -type f -path '*/*-ucode/*' -printf '%%P\n' | sort | tr '\n' ' ')"
cat <<EOF > ../config-microcode
CONFIG_EXTRA_FIRMWARE="${microcode}"
CONFIG_EXTRA_FIRMWARE_DIR="%{_cross_libdir}/firmware"
EOF
%endif

export ARCH="%{_cross_karch}"
export CROSS_COMPILE="%{_cross_target}-"

export KCONFIG_CONFIG="arch/%{_cross_karch}/configs/%{_cross_vendor}_defconfig"
merge_configs=( \
  ../config-%{_cross_arch} \
  %{S:103} \
)
%if "%{_cross_arch}" == "x86_64"
merge_configs+=(../config-microcode %{S:101})
%else
merge_configs+=(%{S:102})
%endif
merge_configs+=(%{S:100} %{S:104})
scripts/kconfig/merge_config.sh "${merge_configs[@]}"
%if %{with lkrg}
base_config="../%{_cross_vendor}_defconfig.base"
cp "${KCONFIG_CONFIG}" "${base_config}"
scripts/kconfig/merge_config.sh "${base_config}" %{S:105}
rm -f "${base_config}"
%endif

# Select the full kernel config based on host and target architecture.
# Kernel 6.18 uses host-arch-specific configs because config generation
# can produce different results depending on the build host.
%if "%{host_arch}" == "aarch64"
  %if "%{_cross_arch}" == "x86_64"
    %if %{with lkrg}
    SOURCE_FILE="%{S:114}"
    %else
    SOURCE_FILE="%{S:110}"
    %endif
  %else
    %if %{with lkrg}
    SOURCE_FILE="%{S:115}"
    %else
    SOURCE_FILE="%{S:111}"
    %endif
  %endif
%else
  %if "%{_cross_arch}" == "x86_64"
    %if %{with lkrg}
    SOURCE_FILE="%{S:116}"
    %else
    SOURCE_FILE="%{S:112}"
    %endif
  %else
    %if %{with lkrg}
    SOURCE_FILE="%{S:117}"
    %else
    SOURCE_FILE="%{S:113}"
    %endif
  %endif
%endif

if ! diff "${KCONFIG_CONFIG}" "${SOURCE_FILE}"; then
  echo "error: source and build kernel configurations do not match"
  exit 1
fi

rm -f ../config-* ../*.patch
cd %{_builddir}

%global kmake %{shrink: \
make -s \
  ARCH="%{_cross_karch}" \
  CROSS_COMPILE="%{_cross_target}-" \
  INSTALL_HDR_PATH="%{buildroot}%{_cross_prefix}" \
  INSTALL_MOD_PATH="%{buildroot}%{_cross_prefix}" \
  INSTALL_MOD_STRIP=1 \
  %{nil}}

%build
%kmake mrproper
%kmake %{_cross_vendor}_defconfig
%kmake %{?_smp_mflags} %{_cross_kimage}
%if %{with lkrg}
%kmake %{?_smp_mflags} modules
%kmake %{?_smp_mflags} M=%{_builddir}/lkrg-%{lkrg_version}
%endif
make -C tools/bpf/bpftool bootstrap
./tools/bpf/bpftool/bootstrap/bpftool btf dump file vmlinux format c > vmlinux.h

%install
%kmake %{?_smp_mflags} headers_install
%if %{with lkrg}
%kmake %{?_smp_mflags} INSTALL_MOD_DIR=extra M=%{_builddir}/lkrg-%{lkrg_version} modules_install
%endif
install -d %{buildroot}/boot
install -T -m 0755 arch/%{_cross_karch}/boot/%{_cross_kimage} %{buildroot}/boot/vmlinuz
install -m 0644 .config %{buildroot}/boot/config

find %{buildroot}%{_cross_prefix} \
   \( -name .install -o -name .check -o \
      -name ..install.cmd -o -name ..check.cmd \) -delete

# Keep enough of the configured kernel tree for inspection and userspace BPF
# development.  Runtime and out-of-tree module loading are intentionally
# unsupported in this minimal kernel.

# Any existing ELF objects will not work properly if we're cross-compiling for
# a different architecture, so get rid of them to avoid confusing errors.
find arch scripts tools -type f -executable \
  -exec sh -c "head -c4 {} | grep -q ELF && rm {}" \;

# We don't need to include these files.
find -type f \( -name \*.cmd -o -name \*.gitignore \) -delete

# Avoid building certificate helper tools that are only useful for module
# signing or trusted keyring extraction.
sed -i \
  -e 's,$(CONFIG_MODULE_SIG_FORMAT),n,g' \
  -e 's,$(CONFIG_SYSTEM_TRUSTED_KEYRING),n,g' \
  scripts/Makefile

(
  find * \
    -type f \
    \( -name Build\* -o -name Kbuild\* -o -name Kconfig\* -o -name Makefile\* \) \
    -print

  find arch/%{_cross_karch}/ \
    -type f \
    \( -name module.lds -o -name vmlinux.lds.S -o -name Platform -o -name \*.tbl \) \
    -print

  find arch/%{_cross_karch}/{include,lib}/ -type f ! -name \*.o ! -name \*.o.d ! -name \*.a -print
  echo arch/%{_cross_karch}/kernel/asm-offsets.s
  echo lib/vdso/gettimeofday.c

  for d in \
    arch/%{_cross_karch}/tools \
    arch/%{_cross_karch}/kernel/vdso ; do
    [ -d "${d}" ] && find "${d}/" -type f ! -name \*.o -print
  done

  find include -type f -print
  find scripts -type f ! -name \*.l ! -name \*.y ! -name \*.o -print

  find tools/{arch/%{_cross_karch},include,objtool,scripts}/ -type f ! -name \*.o ! -name \*.a -print
  echo tools/build/fixdep.c
  find tools/lib/subcmd -type f -print
  find tools/lib/{ctype,hweight,rbtree,string,str_error_r}.c

  echo kernel/bounds.c
  echo kernel/time/timeconst.bc
  echo security/selinux/include/classmap.h
  echo security/selinux/include/initial_sid_to_string.h
  echo security/selinux/include/policycap.h
  echo security/selinux/include/policycap_names.h

  echo .config
  [ -f Module.symvers ] && echo Module.symvers
  echo System.map
  echo vmlinux.h
) | sort -u > kernel_devel_files

# Install development files into the canonical location for use by downstream
# packages as a build dependency.
install -d %{buildroot}%{_cross_ksrcdir}
tar c -T kernel_devel_files | tar x -C %{buildroot}%{_cross_ksrcdir}

install -d %{buildroot}%{_cross_kmoddir}

# Provide conventional build/source links for tooling that locates the
# configured kernel tree from /lib/modules/<release>, even though no loadable
# modules are supported.
rm -f %{buildroot}%{_cross_kmoddir}/build %{buildroot}%{_cross_kmoddir}/source
ln -rs %{_cross_ksrcdir} %{buildroot}%{_cross_kmoddir}/build
ln -rs %{_cross_ksrcdir} %{buildroot}%{_cross_kmoddir}/source

# Make it easy to find sources across minor version changes.
ln -rs %{buildroot}%{_cross_ksrcdir} %{buildroot}%{_cross_usrsrc}/kernels/%{kmajor}
ln -rs %{buildroot}%{_cross_kmoddir} %{buildroot}%{_cross_libdir}/modules/%{kmajor}

# Install a copy of System.map for diagnostics.
install -p -m 0600 System.map %{buildroot}%{_cross_kmoddir}

# Create the mount point for the runtime kernel-devel directory.
install -d %{buildroot}%{_cross_datadir}/bottlerocket/kernel-devel/%{version}/scripts

# Add a drop-in for compatibility with the release package's mount unit.
LOWERPATH=$(systemd-escape --path %{_cross_sharedstatedir}/kernel-devel/.overlay/lower)
mkdir -p %{buildroot}%{_cross_unitdir}/"${LOWERPATH}.mount.d"
sed -e 's|PREFIX|%{_cross_prefix}|g' %{S:210} \
  > %{buildroot}%{_cross_unitdir}/"${LOWERPATH}.mount.d"/no-squashfs.conf

# Add symlink for kernel 6.18 xfsprogs-mkfs defaults in the default path.
mkdir -p %{buildroot}%{_cross_datadir}/xfsprogs/mkfs
ln -s lts_6.18.conf %{buildroot}%{_cross_datadir}/xfsprogs/mkfs/default.conf

# Install platform-specific bootconfig snippets.
install -d %{buildroot}%{_cross_bootconfigdir}
install -p -m 0644 %{S:300} %{buildroot}%{_cross_bootconfigdir}/05-aws.conf
install -p -m 0644 %{S:301} %{buildroot}%{_cross_bootconfigdir}/05-vmware.conf

%if %{with lkrg}
# Load LKRG during boot and immediately close the module-loading window.
install -d %{buildroot}%{_cross_unitdir}
install -p -m 0644 %{S:401} %{buildroot}%{_cross_unitdir}/load-lkrg-module.service
%endif

%files
%license COPYING LICENSES/preferred/GPL-2.0 LICENSES/exceptions/Linux-syscall-note
%if %{with lkrg}
%license ../lkrg-%{lkrg_version}/LICENSE
%endif
%{_cross_attribution_file}
/boot/vmlinuz
/boot/config
%dir %{_cross_usrsrc}/kernels
%dir %{_cross_datadir}/bottlerocket/kernel-devel
%{_cross_datadir}/bottlerocket/kernel-devel/*
%{_cross_unitdir}/*kernel*devel*.mount.d/no-squashfs.conf
%if %{with lkrg}
%dir %{_cross_libdir}/modules
%dir %{_cross_kmoddir}
%dir %{_cross_kmoddir}/extra
%{_cross_kmoddir}/extra/lkrg.%{_ko}
%{_cross_kmoddir}/modules.*
%{_cross_unitdir}/load-lkrg-module.service
%endif

%files mkfs-xfs-conf
%{_cross_datadir}/xfsprogs/mkfs/default.conf

%files headers
%dir %{_cross_includedir}/asm
%dir %{_cross_includedir}/asm-generic
%dir %{_cross_includedir}/cxl
%dir %{_cross_includedir}/drm
%dir %{_cross_includedir}/fwctl
%dir %{_cross_includedir}/linux
%dir %{_cross_includedir}/misc
%dir %{_cross_includedir}/mtd
%dir %{_cross_includedir}/rdma
%dir %{_cross_includedir}/regulator
%dir %{_cross_includedir}/scsi
%dir %{_cross_includedir}/sound
%dir %{_cross_includedir}/video
%dir %{_cross_includedir}/xen
%{_cross_includedir}/asm/*
%{_cross_includedir}/asm-generic/*
%{_cross_includedir}/cxl/*
%{_cross_includedir}/drm/*
%{_cross_includedir}/fwctl/*
%{_cross_includedir}/linux/*
%{_cross_includedir}/misc/*
%{_cross_includedir}/mtd/*
%{_cross_includedir}/rdma/*
%{_cross_includedir}/regulator/*
%{_cross_includedir}/scsi/*
%{_cross_includedir}/sound/*
%{_cross_includedir}/video/*
%{_cross_includedir}/xen/*

%files devel
# Allow downstream package builds to modify these files, since they need to
# rebuild tools for the current host architecture.
%defattr(664, root, builder, 775)
%{_cross_usrsrc}/kernels/%{kmajor}
%{_cross_ksrcdir}
%dir %{_cross_libdir}/modules
%dir %{_cross_kmoddir}
%{_cross_libdir}/modules/%{kmajor}
%{_cross_kmoddir}/source
%{_cross_kmoddir}/build
%{_cross_kmoddir}/System.map
%attr(775, root, builder) %{_cross_ksrcdir}/scripts/*

%files bootconfig-aws
%{_cross_bootconfigdir}/05-aws.conf

%files bootconfig-vmware
%{_cross_bootconfigdir}/05-vmware.conf

%changelog
