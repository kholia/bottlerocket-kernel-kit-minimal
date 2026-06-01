#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

KERNEL_VERSION="6.18"
ARCH=""
PACKAGE_NAME=""
INCLUDE_LKRG=1
GENERATE_CONFIG=1
BUILD_KERNEL=1
RUN_QEMU=1
USE_KVM=1
QEMU_CPU=()
ENABLE_NET=1
QEMU_NET=()
KEEP_WORK=0
MEMORY="1024"
SMP="2"
KERNEL_OUT="/tmp/br-kernel-6.18"
INITRAMFS="/tmp/br-smoke-rootfs.ext4"
ROOTFS_SIZE_MIB="32"
CMDLINE="console=ttyS0 earlyprintk=serial panic=0 root=/dev/vda ro rootfstype=ext4 rootwait init=/init"
QEMU_EXTRA=()
SPEC_PATH=""
SPEC_BACKUP=""
INITRAMFS_WORK=""
BUSYBOX_CAN_RUN=0
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:stable-musl}"
MKFS_EXT4=()

usage() {
    cat <<'EOF'
Usage: tools/qemu-smoke-kernel-6.18.sh [OPTIONS] [-- QEMU_ARGS...]

Build the Bottlerocket kernel-6.18 package, extract /boot/vmlinuz, create a
minimal BusyBox rootfs image, and direct-boot the kernel in QEMU.

Fresh clones can use --no-build to reuse the committed kernel smoke-test RPM
under build/rpms/kernel-6.18 instead of rebuilding the kernel package.

LKRG is enabled by default. The smoke rootfs loads /lkrg.ko with
kint_enforce=1 and then sets /proc/sys/kernel/modules_disabled to 1.

This is a kernel/LKRG smoke test, not a full Bottlerocket image boot. For
systemd, bootconfig, host-container behavior, and the real LKRG systemd unit,
build a Bottlerocket variant image.

Options:
  --arch ARCH          Build/test architecture. Direct QEMU boot supports x86_64.
                       Default: current host architecture. On macOS ARM64, the
                       default is x86_64 because direct smoke boot is x86_64.
  --kernel VERSION     Kernel package line. Default: 6.18.
  --package NAME       Cargo package name. Default: kernel-<VERSION with . as _>.
  --without-lkrg       Build/test the regular module-less kernel instead.
  --no-config          Do not regenerate full configs before building.
  --no-build           Reuse an existing built RPM under build/rpms/kernel-6.18.
  --no-run             Build/extract/create rootfs image, but do not start QEMU.
  --no-kvm             Do not pass -enable-kvm -cpu host to QEMU.
  --no-net             Do not attach the default QEMU user-mode network.
  --memory MB          QEMU memory in MiB. Default: 1024.
  --smp CPUS           QEMU vCPU count. Default: 2.
  --output-dir DIR     Extraction directory for /boot/vmlinuz. Default: /tmp/br-kernel-6.18.
  --initramfs PATH     Rootfs image output path. Default: /tmp/br-smoke-rootfs.ext4.
  --append CMDLINE     Kernel command line.
  --keep-work          Keep temporary rootfs staging directory.
  -h, --help           Show this help.

Dependencies on Ubuntu:
  sudo apt install qemu-system-x86 busybox-static rpm2cpio cpio e2fsprogs wget ca-certificates

Dependencies on macOS ARM64:
  brew install qemu e2fsprogs wget
  Docker Desktop must be running if a Linux static BusyBox is not already available.

Examples:
  tools/qemu-smoke-kernel-6.18.sh
  tools/qemu-smoke-kernel-6.18.sh --no-build
  tools/qemu-smoke-kernel-6.18.sh --no-build --no-run
  tools/qemu-smoke-kernel-6.18.sh --without-lkrg
EOF
}

bail() {
    echo "error: $*" >&2
    exit 1
}

warn() {
    echo "warning: $*" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || bail "missing command '$1'"
}

normalize_arch() {
    case "$1" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

default_smoke_arch() {
    local host_arch

    host_arch="$(normalize_arch "${HOST_ARCH}")"
    if [[ "${HOST_OS}" == "Darwin" && "${host_arch}" == "aarch64" ]]; then
        echo "x86_64"
    else
        echo "${host_arch}"
    fi
}

docker_platform_for_arch() {
    case "${ARCH}" in
        x86_64)
            echo "linux/amd64"
            ;;
        aarch64)
            echo "linux/arm64"
            ;;
        *)
            bail "no Docker platform mapping for architecture '${ARCH}'"
            ;;
    esac
}

find_mkfs_ext4() {
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        MKFS_EXT4=(mkfs.ext4)
    elif command -v mke2fs >/dev/null 2>&1; then
        MKFS_EXT4=(mke2fs -t ext4)
    else
        bail "missing command 'mkfs.ext4' or 'mke2fs'"
    fi
}

run_mkfs_ext4() {
    "${MKFS_EXT4[@]}" -q -F -d "${INITRAMFS_WORK}" -L BRSMOKE "${INITRAMFS}"
}

rpm_list() {
    local rpm="$1"

    if command -v rpm2cpio >/dev/null 2>&1; then
        need_cmd cpio
        rpm2cpio "${rpm}" | cpio -t 2>/dev/null
    else
        need_cmd tar
        tar -tf "${rpm}"
    fi
}

rpm_extract() {
    local rpm="$1"
    shift

    if command -v rpm2cpio >/dev/null 2>&1; then
        need_cmd cpio
        rpm2cpio "${rpm}" | cpio -idmv "$@"
    else
        need_cmd tar
        tar -xf "${rpm}" "$@"
    fi
}

find_busybox() {
    local host_arch
    local busybox_path
    local busybox_out
    local platform

    host_arch="$(normalize_arch "${HOST_ARCH}")"
    busybox_path="$(command -v busybox || true)"
    if [[ "${HOST_OS}" == "Linux" && "${host_arch}" == "${ARCH}" && -n "${busybox_path}" ]]; then
        BUSYBOX_CAN_RUN=1
        echo "${busybox_path}"
        return
    fi

    need_cmd docker
    platform="$(docker_platform_for_arch)"
    busybox_out="${TMPDIR:-/tmp}/br-smoke-busybox-${ARCH}"

    echo "No executable Linux ${ARCH} BusyBox found on the host; extracting one from ${BUSYBOX_IMAGE} (${platform})..." >&2
    if ! docker run --rm --platform "${platform}" "${BUSYBOX_IMAGE}" cat /bin/busybox > "${busybox_out}"; then
        rm -f "${busybox_out}"
        bail "failed to extract BusyBox from Docker image '${BUSYBOX_IMAGE}' for ${platform}"
    fi
    chmod +x "${busybox_out}"
    BUSYBOX_CAN_RUN=0
    echo "${busybox_out}"
}

cleanup() {
    restore_spec

    if [[ -n "${INITRAMFS_WORK}" && -d "${INITRAMFS_WORK}" ]]; then
        if [[ "${KEEP_WORK}" -eq 0 ]]; then
            rm -rf "${INITRAMFS_WORK}"
        else
            echo "Kept rootfs staging directory: ${INITRAMFS_WORK}"
        fi
    fi
}
trap cleanup EXIT

restore_spec() {
    if [[ -n "${SPEC_BACKUP}" && -f "${SPEC_BACKUP}" ]]; then
        cp "${SPEC_BACKUP}" "${SPEC_PATH}"
        rm -f "${SPEC_BACKUP}"
        SPEC_BACKUP=""
        echo "Restored ${SPEC_PATH}"
    fi
}

is_static_binary() {
    local binary="$1"
    local binary_info
    local ldd_output

    if command -v ldd >/dev/null 2>&1; then
        ldd_output="$(ldd "${binary}" 2>&1 || true)"
        [[ "${ldd_output}" == *"not a dynamic executable"* || "${ldd_output}" == *"statically linked"* ]] && return
    fi

    if command -v file >/dev/null 2>&1; then
        binary_info="$(file "${binary}")"
        [[ "${binary_info}" == *"ELF"* && ( "${binary_info}" == *"statically linked"* || "${binary_info}" == *"static-pie linked"* ) ]] && return
    fi

    return 1
}

copy_rootfs_path() {
    local src="$1"
    local dest

    [[ -e "${src}" ]] || return 0

    dest="${INITRAMFS_WORK}${src}"
    mkdir -p "$(dirname "${dest}")"
    cp -aL "${src}" "${dest}"
}

copy_host_binary() {
    local binary="$1"
    local lib

    [[ "${HOST_OS}" == "Linux" ]] || return 1
    [[ -x "${binary}" ]] || return 1

    copy_rootfs_path "${binary}"
    while IFS= read -r lib; do
        copy_rootfs_path "${lib}"
    done < <(ldd "${binary}" | awk '
        $1 == "linux-vdso.so.1" { next }
        $2 == "=>" && $3 ~ /^\// { print $3; next }
        $1 ~ /^\// { print $1; next }
    ')
}

copy_https_tools() {
    local host_arch
    local host_wget
    local nss_lib

    host_arch="$(normalize_arch "${HOST_ARCH}")"
    if [[ "${HOST_OS}" != "Linux" || "${host_arch}" != "${ARCH}" ]]; then
        warn "host HTTPS tools are not copied for ${HOST_OS}/${HOST_ARCH}; guest fetches will use BusyBox wget"
        return
    fi

    host_wget="$(command -v wget || true)"
    if [[ -z "${host_wget}" ]]; then
        warn "host wget not found; guest HTTPS fetches will use BusyBox wget"
        return
    fi

    copy_host_binary "${host_wget}"
    for nss_lib in \
        "/lib/${ARCH}-linux-gnu/libnss_dns.so.2" \
        "/lib/${ARCH}-linux-gnu/libnss_files.so.2" \
        "/usr/lib/${ARCH}-linux-gnu/libnss_dns.so.2" \
        "/usr/lib/${ARCH}-linux-gnu/libnss_files.so.2" \
        /lib64/libnss_dns.so.2 \
        /lib64/libnss_files.so.2 \
        /lib/libnss_dns.so.2 \
        /lib/libnss_files.so.2; do
        copy_rootfs_path "${nss_lib}"
    done
    copy_rootfs_path /etc/ssl/certs/ca-certificates.crt

    echo "hosts: files dns" > "${INITRAMFS_WORK}/etc/nsswitch.conf"
    echo "127.0.0.1 localhost" > "${INITRAMFS_WORK}/etc/hosts"
    cat > "${INITRAMFS_WORK}/etc/profile" <<'EOF'
if [ -x /usr/bin/wget ]; then
    alias wget=/usr/bin/wget
fi
EOF
}

enable_lkrg_spec_default() {
    SPEC_PATH="packages/kernel-${KERNEL_VERSION}/kernel-${KERNEL_VERSION}.spec"
    [[ -f "${SPEC_PATH}" ]] || bail "missing kernel spec: ${SPEC_PATH}"

    if grep -q '^%bcond_without lkrg$' "${SPEC_PATH}"; then
        echo "LKRG is already enabled by default in ${SPEC_PATH}"
        return
    fi

    grep -q '^%bcond_with lkrg$' "${SPEC_PATH}" || bail "could not find LKRG bcond in ${SPEC_PATH}"

    SPEC_BACKUP="$(mktemp)"
    cp "${SPEC_PATH}" "${SPEC_BACKUP}"
    sed -i 's/^%bcond_with lkrg$/%bcond_without lkrg/' "${SPEC_PATH}"
    echo "Temporarily enabled LKRG by default in ${SPEC_PATH}"
}

clear_lkrg_package_artifacts() {
    local package_rpms="build/rpms/kernel-${KERNEL_VERSION}"
    local package_state="build/state/${ARCH}/packages/kernel-${KERNEL_VERSION}"
    local kit_package_state="build/state/${ARCH}/kits/bottlerocket-kernel-kit/${ARCH}/Packages/kernel-${KERNEL_VERSION}"

    echo "Clearing cached kernel-${KERNEL_VERSION} package artifacts for LKRG rebuild..."
    rm -rf "${package_rpms}" "${package_state}" "${kit_package_state}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ $# -ge 2 ]] || bail "--arch requires a value"
            ARCH="$2"
            shift 2
            ;;
        --kernel)
            [[ $# -ge 2 ]] || bail "--kernel requires a value"
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --package)
            [[ $# -ge 2 ]] || bail "--package requires a value"
            PACKAGE_NAME="$2"
            shift 2
            ;;
        --without-lkrg)
            INCLUDE_LKRG=0
            shift
            ;;
        --no-config)
            GENERATE_CONFIG=0
            shift
            ;;
        --no-build)
            BUILD_KERNEL=0
            shift
            ;;
        --no-run)
            RUN_QEMU=0
            shift
            ;;
        --no-kvm)
            USE_KVM=0
            shift
            ;;
        --no-net)
            ENABLE_NET=0
            shift
            ;;
        --memory)
            [[ $# -ge 2 ]] || bail "--memory requires a value"
            MEMORY="$2"
            shift 2
            ;;
        --smp)
            [[ $# -ge 2 ]] || bail "--smp requires a value"
            SMP="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || bail "--output-dir requires a value"
            KERNEL_OUT="$2"
            shift 2
            ;;
        --initramfs)
            [[ $# -ge 2 ]] || bail "--initramfs requires a value"
            INITRAMFS="$2"
            shift 2
            ;;
        --append)
            [[ $# -ge 2 ]] || bail "--append requires a value"
            CMDLINE="$2"
            shift 2
            ;;
        --keep-work)
            KEEP_WORK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            QEMU_EXTRA=("$@")
            break
            ;;
        *)
            bail "unknown argument '$1'"
            ;;
    esac
done

if [[ -z "${ARCH}" ]]; then
    ARCH="$(default_smoke_arch)"
fi
ARCH="$(normalize_arch "${ARCH}")"

case "${ARCH}" in
    x86_64)
        QEMU_BIN="qemu-system-x86_64"
        ;;
    *)
        bail "direct QEMU smoke boot currently supports x86_64 only; got '${ARCH}'"
        ;;
esac

if [[ -z "${PACKAGE_NAME}" ]]; then
    PACKAGE_NAME="kernel-${KERNEL_VERSION//./_}"
fi

if [[ "${INCLUDE_LKRG}" -eq 1 && "${KERNEL_VERSION}" != "6.18" ]]; then
    bail "LKRG support in this repo is wired for kernel 6.18 only"
fi

case "${KERNEL_OUT}" in
    ""|"/"|"/boot"|"/tmp"|"/var"|"/home"|".")
        bail "refusing unsafe --output-dir '${KERNEL_OUT}'"
        ;;
esac

cd "${REPO_ROOT}"

need_cmd grep
need_cmd make
need_cmd truncate
if ! command -v rpm2cpio >/dev/null 2>&1; then
    need_cmd tar
fi
find_mkfs_ext4

if [[ "${RUN_QEMU}" -eq 1 ]]; then
    need_cmd "${QEMU_BIN}"
fi

BUSYBOX="$(find_busybox)"
[[ -n "${BUSYBOX}" && -s "${BUSYBOX}" ]] || bail "missing static Linux BusyBox"
is_static_binary "${BUSYBOX}" || bail "'${BUSYBOX}' is not a static Linux binary"
if [[ "${BUSYBOX_CAN_RUN}" -eq 1 ]]; then
    "${BUSYBOX}" --list | grep -qx zcat || bail "'${BUSYBOX}' does not include the zcat applet"
fi

if [[ "${BUILD_KERNEL}" -eq 1 ]]; then
    if [[ "${GENERATE_CONFIG}" -eq 1 ]]; then
        if [[ "${INCLUDE_LKRG}" -eq 1 ]]; then
            echo "Regenerating LKRG full config for kernel ${KERNEL_VERSION}..."
            make "full-config-kernel-${KERNEL_VERSION}-lkrg"
        else
            echo "Regenerating full config for kernel ${KERNEL_VERSION}..."
            make "full-config-kernel-${KERNEL_VERSION}"
        fi
    fi

    if [[ "${INCLUDE_LKRG}" -eq 1 ]]; then
        enable_lkrg_spec_default
        clear_lkrg_package_artifacts
    fi

    build_suffix=""
    if [[ "${INCLUDE_LKRG}" -eq 1 ]]; then
        build_suffix=" with LKRG"
    fi
    echo "Building ${PACKAGE_NAME} for ${ARCH}${build_suffix}..."
    env PACKAGE="${PACKAGE_NAME}" make ARCH="${ARCH}" twoliter build-package
    restore_spec
fi

shopt -s nullglob
rpms=( "build/rpms/kernel-${KERNEL_VERSION}/bottlerocket-kernel-${KERNEL_VERSION}-"[0-9]*."${ARCH}".rpm )
shopt -u nullglob
[[ "${#rpms[@]}" -gt 0 ]] || bail "no kernel RPM found under build/rpms/kernel-${KERNEL_VERSION}"

rpm="$(ls -t "${rpms[@]}" | head -n1)"
echo "Using RPM: ${rpm}"

lkrg_member=""
if [[ "${INCLUDE_LKRG}" -eq 1 ]]; then
    lkrg_member="$(rpm_list "${REPO_ROOT}/${rpm}" | grep -E '(^|/)lkrg\.ko$' | head -n1 || true)"
    [[ -n "${lkrg_member}" ]] || bail "RPM does not contain lkrg.ko; rebuild without --no-build or inspect the LKRG bcond"
    echo "Found LKRG module in RPM: ${lkrg_member}"
fi

mkdir -p "${KERNEL_OUT}"
rm -rf "${KERNEL_OUT}/boot" "${KERNEL_OUT}/${ARCH}-bottlerocket-linux-gnu"
(
    cd "${KERNEL_OUT}"
    extract_members=( './boot/vmlinuz' './boot/config' )
    if [[ -n "${lkrg_member}" ]]; then
        extract_members+=( "${lkrg_member}" )
    fi
    rpm_extract "${REPO_ROOT}/${rpm}" "${extract_members[@]}"
)
[[ -s "${KERNEL_OUT}/boot/vmlinuz" ]] || bail "failed to extract ${KERNEL_OUT}/boot/vmlinuz"
grep -q '^CONFIG_IKCONFIG=y$' "${KERNEL_OUT}/boot/config" || bail "config.gz check failed: CONFIG_IKCONFIG is not enabled"
grep -q '^CONFIG_IKCONFIG_PROC=y$' "${KERNEL_OUT}/boot/config" || bail "config.gz check failed: CONFIG_IKCONFIG_PROC is not enabled"

INITRAMFS_WORK="$(mktemp -d)"

mkdir -p "${INITRAMFS_WORK}/bin" "${INITRAMFS_WORK}/dev" "${INITRAMFS_WORK}/etc" "${INITRAMFS_WORK}/proc" "${INITRAMFS_WORK}/sys" "${INITRAMFS_WORK}/tmp"
chmod 1777 "${INITRAMFS_WORK}/tmp"
cp "${BUSYBOX}" "${INITRAMFS_WORK}/bin/busybox"
ln -s busybox "${INITRAMFS_WORK}/bin/sh"
copy_https_tools

if [[ "${INCLUDE_LKRG}" -eq 1 ]]; then
    grep -q '^CONFIG_MODULES=y$' "${KERNEL_OUT}/boot/config" || bail "LKRG config check failed: CONFIG_MODULES is not enabled"
    grep -q '^CONFIG_MODULE_SIG_FORCE=y$' "${KERNEL_OUT}/boot/config" || bail "LKRG config check failed: CONFIG_MODULE_SIG_FORCE is not enabled"

    LKRG_KO="$(find "${KERNEL_OUT}" -type f -name 'lkrg.ko' -print -quit)"
    [[ -n "${LKRG_KO}" && -s "${LKRG_KO}" ]] || bail "extracted RPM did not include lkrg.ko"
    cp "${LKRG_KO}" "${INITRAMFS_WORK}/lkrg.ko"
fi

cat > "${INITRAMFS_WORK}/init" <<'EOF'
#!/bin/sh
BB=/bin/busybox

"${BB}" mount -t proc none /proc
"${BB}" mount -t sysfs none /sys
"${BB}" mount -o remount,rw / 2>/dev/null || true

echo "Configuring QEMU user-mode network..."
"${BB}" ip link set lo up || true
if "${BB}" ip link show eth0 >/dev/null 2>&1; then
    "${BB}" ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || true
    "${BB}" ip link set eth0 up || true
    "${BB}" ip route add default via 10.0.2.2 dev eth0 2>/dev/null || true
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    "${BB}" ip -4 addr show dev eth0 | "${BB}" sed 's/^/  /'
    "${BB}" ip route | "${BB}" sed 's/^/  /'

    if "${BB}" grep -qw smoke_check_internet=1 /proc/cmdline; then
        if "${BB}" wget -q -T 10 -O /dev/null http://example.com/; then
            echo "Internet check succeeded"
        else
            echo "Internet check failed"
        fi
    fi
else
    echo "No eth0 interface found; run without --no-net and keep the default QEMU network."
fi

echo "Checking /proc/config.gz..."
if "${BB}" zcat /proc/config.gz >/dev/null; then
    "${BB}" zcat /proc/config.gz | "${BB}" grep -E '^(CONFIG_IKCONFIG|CONFIG_IKCONFIG_PROC|CONFIG_MODULES|CONFIG_MODULE_UNLOAD|CONFIG_MODULE_SIG_FORCE|CONFIG_JUMP_LABEL|CONFIG_SECURITY_DMESG_RESTRICT|CONFIG_SLAB_FREELIST_RANDOM|CONFIG_SLAB_FREELIST_HARDENED|CONFIG_SLAB_BUCKETS|CONFIG_RANDOM_KMALLOC_CACHES|CONFIG_SHUFFLE_PAGE_ALLOCATOR|CONFIG_INIT_STACK_ALL_ZERO|CONFIG_INIT_ON_ALLOC_DEFAULT_ON|CONFIG_ZERO_CALL_USED_REGS|CONFIG_FORTIFY_SOURCE|CONFIG_HARDENED_USERCOPY|CONFIG_HARDENED_USERCOPY_DEFAULT_ON|CONFIG_LIST_HARDENED|CONFIG_BUG_ON_DATA_CORRUPTION|CONFIG_DEBUG_WX|CONFIG_STRICT_DEVMEM|CONFIG_IO_STRICT_DEVMEM|CONFIG_X86_USER_SHADOW_STACK|CONFIG_MITIGATION_SLS)='
else
    echo "Failed to read /proc/config.gz"
fi

echo "Checking CPU hardening flags..."
"${BB}" grep -m1 '^flags' /proc/cpuinfo | "${BB}" grep -Ew 'smep|smap|umip|ibt' || true

if [ -f /lkrg.ko ]; then
    echo "Loading LKRG..."
    if "${BB}" insmod /lkrg.ko kint_enforce=1; then
        echo 1 > /proc/sys/kernel/modules_disabled
        modules_disabled="$("${BB}" cat /proc/sys/kernel/modules_disabled)"
        echo "LKRG loaded; modules_disabled=${modules_disabled}"
    else
        echo "LKRG load failed"
    fi
fi

echo "Booted: $("${BB}" uname -a)"
if "${BB}" grep -qw smoke_poweroff=1 /proc/cmdline; then
    "${BB}" poweroff -f
fi
ENV=/etc/profile exec /bin/sh
EOF
chmod +x "${INITRAMFS_WORK}/init"

mkdir -p "$(dirname "${INITRAMFS}")"
rm -f "${INITRAMFS}"
truncate -s "${ROOTFS_SIZE_MIB}M" "${INITRAMFS}"
run_mkfs_ext4
echo "Wrote rootfs image: ${INITRAMFS}"

if [[ "${RUN_QEMU}" -eq 0 ]]; then
    echo "Skipping QEMU run because --no-run was set."
    echo "Kernel: ${KERNEL_OUT}/boot/vmlinuz"
    exit 0
fi

qemu_accel=()
if [[ "${USE_KVM}" -eq 1 ]]; then
    if [[ "${HOST_OS}" == "Darwin" ]]; then
        echo "KVM is unavailable on macOS; using QEMU TCG."
        QEMU_CPU=(-cpu max,+smep,+smap)
    elif [[ -r /dev/kvm && -w /dev/kvm ]]; then
        qemu_accel=(-enable-kvm -cpu host)
    else
        echo "KVM requested but /dev/kvm is not accessible; falling back to TCG."
        QEMU_CPU=(-cpu max,+smep,+smap)
    fi
else
    QEMU_CPU=(-cpu max,+smep,+smap)
fi

if [[ "${ENABLE_NET}" -eq 1 ]]; then
    QEMU_NET=(-netdev user,id=net0 -device virtio-net-pci,netdev=net0)
else
    QEMU_NET=(-nic none)
fi

qemu_cmd=(
    "${QEMU_BIN}"
    -m "${MEMORY}"
    -smp "${SMP}"
)
if [[ "${#qemu_accel[@]}" -gt 0 ]]; then
    qemu_cmd+=( "${qemu_accel[@]}" )
fi
if [[ "${#QEMU_CPU[@]}" -gt 0 ]]; then
    qemu_cmd+=( "${QEMU_CPU[@]}" )
fi
qemu_cmd+=(
    -nographic
    -kernel "${KERNEL_OUT}/boot/vmlinuz"
    -drive "file=${INITRAMFS},format=raw,if=virtio"
    -append "${CMDLINE}"
)
if [[ "${#QEMU_NET[@]}" -gt 0 ]]; then
    qemu_cmd+=( "${QEMU_NET[@]}" )
fi
if [[ "${#QEMU_EXTRA[@]}" -gt 0 ]]; then
    qemu_cmd+=( "${QEMU_EXTRA[@]}" )
fi

echo "Starting QEMU. Use Ctrl-a x to quit."
"${qemu_cmd[@]}"
