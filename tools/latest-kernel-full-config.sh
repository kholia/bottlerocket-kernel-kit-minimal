#!/usr/bin/env bash

set -e -o pipefail

KERNEL_KIT_DIR="/bottlerocket-kernel-kit"
MICROCODE_DIR="${KERNEL_KIT_DIR}/packages/microcode"

# Usage information
usage() {
    cat <<EOF
Usage: $0 [--kernel <major.minor>] [--with-lkrg|--without-lkrg]

This script generates and validates full kernel configurations for all available
kernel versions in the Bottlerocket kernel kit.

IMPORTANT: This script is designed to run inside the Bottlerocket SDK container
and should typically be invoked via the Makefile target:

    make full-config

To limit work to kernel 6.18 only:

    make full-config-kernel-6.18

To generate the optional kernel 6.18 LKRG configuration:

    make full-config-kernel-6.18-lkrg

Running this script directly outside the SDK container will fail because it
requires the proper build environment and mounted paths.

The script will:
1. Discover all kernel-* packages with available RPMs
2. Extract and patch kernel sources
3. Merge Bottlerocket-specific configurations
4. Generate full configuration files
5. Validate that all required configs are present

EOF
}

# Common error handling
bail() {
    if [[ $# -gt 0 ]]; then
        >&2 echo "Error: $*"
    fi
    exit 1
}

kernel_filter=""
with_lkrg=0

normalize_kernel_filter() {
    local kernel="$1"
    kernel="${kernel#kernel-}"
    echo "${kernel}"
}

kernel_dir_selected() {
    local kernel_dir="$1"
    local kernel_pkg
    kernel_pkg=$(basename "${kernel_dir}")

    [[ -z "${kernel_filter}" || "${kernel_pkg}" == "kernel-${kernel_filter}" ]]
}

# Get the config-full filename for a given kernel version and architecture
get_kernel_config_file_name() {
    local majorminor="$1"
    local arch="$2"
    local flavor="${3:-default}"
    if [[ "${majorminor}" == "6.18" ]]; then
        if [[ "${flavor}" == "lkrg" ]]; then
            echo "config-full-bottlerocket-lkrg-${arch}-on-$(uname -m)"
        else
            echo "config-full-bottlerocket-${arch}-on-$(uname -m)"
        fi
    else
        echo "config-full-bottlerocket-${arch}"
    fi
}

# Fetch the sources of the configured kernels
fetch_sources() {
    # Use the tools available in the Bottlerocket SDK (curl, grep , sed) since
    # the running container is configured with the caller's UID which prevents
    # from installing tools at /home/builder/
    for kernel_dir in "${KERNEL_KIT_DIR}/packages"/kernel-*; do
        kernel_dir_selected "${kernel_dir}" || continue

        pushd "${kernel_dir}" || bail "Unable to enter kernel directory '${kernel_dir}'"
        grep 'url =' "Cargo.toml" | while IFS= read -r url; do
            url=$(echo "${url#*\"}" | cut -d '"' -f 1)
            echo "Fetching: ${url}"
            curl -LOs "${url}"
        done
        popd || bail "Could not exit kernel directory '${kernel_dir}'"
    done
}

# Generate merged kernel configs for each architecture.
generate_kernel_configs() {
    local version="$1"
    local kernel_path="$2"
    local microcode_file="$3"
    local majorminor="$4"
    for arch in "x86_64" "aarch64"; do
        br_cfg="${kernel_path}/config-bottlerocket"
        br_cfg_arch="${kernel_path}/config-bottlerocket-${arch}"
        br_cfg_minimal="${kernel_path}/config-minimal-bottlerocket"
        br_cfg_hardening="${kernel_path}/config-bottlerocket-hardening"
        br_cfg_lkrg="${kernel_path}/config-bottlerocket-lkrg"
        microcode_cfg="${MICROCODE_DIR}/${microcode_file}"
        if ((with_lkrg)); then
            if [[ "${majorminor}" != "6.18" ]]; then
                bail "--with-lkrg is only supported for kernel 6.18"
            fi
            config_filename=$(get_kernel_config_file_name "${majorminor}" "${arch}" "lkrg")
        else
            config_filename=$(get_kernel_config_file_name "${majorminor}" "${arch}")
        fi

        pushd "linux-${version}" || bail "Could not move into linux-${version}"

        if [ "${arch}" = "aarch64" ]; then
            karch="arm64"
            script_args=("../config-${arch}" "${br_cfg_minimal}" "${br_cfg_arch}" "${br_cfg}" "${br_cfg_hardening}")
        elif [ "${arch}" = "x86_64" ]; then
            karch="x86"
            script_args=("../config-${arch}" "${br_cfg_minimal}" "${microcode_cfg}" "${br_cfg_arch}" "${br_cfg}" "${br_cfg_hardening}")
        fi

        ARCH=${karch} \
            CROSS_COMPILE=/usr/bin/${arch}-bottlerocket-linux-gnu- \
            KCONFIG_CONFIG=bottlerocket_${arch}_defconfig \
            ./scripts/kconfig/merge_config.sh "${script_args[@]}"

        if ((with_lkrg)); then
            base_config="bottlerocket_${arch}_base_defconfig"
            cp "bottlerocket_${arch}_defconfig" "${base_config}"
            ARCH=${karch} \
                CROSS_COMPILE=/usr/bin/${arch}-bottlerocket-linux-gnu- \
                KCONFIG_CONFIG=bottlerocket_${arch}_defconfig \
                ./scripts/kconfig/merge_config.sh "${base_config}" "${br_cfg_lkrg}"
            rm -f "${base_config}"
        fi

        mv -f "bottlerocket_${arch}_defconfig" "${kernel_path}/${config_filename}" || bail "Failed to create ${config_filename}"
        popd || bail "Could not move around - 'popd' failed in merge_config loop. Lets stop before we break anything further."
    done
}

# Function to merge kernel configurations for a specific kernel version
merge_kernel_configs() {
    local version="$1"
    local majorminor="$2"
    local tmpdir="$3"

    local kernel_package_dir="${KERNEL_KIT_DIR}/packages/kernel-${majorminor}"

    readarray -t br_patches < <(find "${kernel_package_dir}" -maxdepth 1 -name "*.patch")

    if [[ "${majorminor}" == "6.18" ]]; then
        spec_file="kernel6.18.spec"
        microcode_file="config-microcode-6-18"
    elif [[ "${majorminor}" == "6.12" ]]; then
        spec_file="kernel6.12.spec"
        microcode_file="config-microcode-6-12"
    else
        spec_file="kernel.spec"
        microcode_file="config-microcode"
    fi

    local kernel_path="${kernel_package_dir}"

    pushd "${tmpdir}" || bail "Unable to enter temporary directory"

    rpm2cpio kernel-source.rpm | cpio -iu {,./}linux-"${version}".tar{,.xz} {,./}config-x86_64 {,./}config-aarch64 {,./}"*.patch" {,./}"${spec_file}"

    # Upstream source is either xz compressed tarball or plain tarball
    if [ -f "./linux-${version}.tar" ]; then
        tar -xof linux-"${version}".tar
        rm linux-"${version}".tar
    else
        tar -xof linux-"${version}".tar.xz
        rm linux-"${version}".tar.xz
    fi

    # Find upstream patch ordering based on the upstream SRPM so we can apply in that order
    readarray -t patches < <(grep -P "^Patch\d+" "${spec_file}" | sort -n -k1.6 | grep -oP "^Patch\d+: \K.*\.patch$" "${spec_file}")

    # Enter the source directory extracted from the tarball and patch
    pushd "linux-${version}" || bail "Could not move into linux-${version}"

    # Patches from the upstream
    for patch in "${patches[@]}"; do
        patch -p1 <"../$patch"
    done

    # Patches from bottlerocket
    for patch in "${br_patches[@]}"; do
        echo "Applying bottlerocket patch ${patch}"
        patch -p1 <"$patch"
    done

    popd || bail "Could not move around - 'popd' back to /work failed. Lets stop before we break anything further."

    generate_kernel_configs "${version}" "${kernel_path}" "${microcode_file}" "${majorminor}"

    popd || bail "Could not return from temporary directory"
}

# Function to validate kernel configurations (similar to validate_config.sh)
validate_kernel_configs() {
    local version="$1"
    local majorminor="$2"
    local errors=0
    local kernel_path="${KERNEL_KIT_DIR}/packages/kernel-${majorminor}"

    for arch in x86_64 aarch64; do
        echo "=== Validating kernel-${majorminor} ${arch} ==="

        # Check if files exist
        if [[ ! -f "${kernel_path}/config-bottlerocket" ]]; then
            echo "❌ Missing config-bottlerocket"
            ((++errors))
            continue
        fi
        if [[ ! -f "${kernel_path}/config-bottlerocket-${arch}" ]]; then
            echo "❌ Missing config-bottlerocket-${arch}"
            ((++errors))
            continue
        fi
        if [[ ! -f "${kernel_path}/config-minimal-bottlerocket" ]]; then
            echo "❌ Missing config-minimal-bottlerocket"
            ((++errors))
            continue
        fi
        if [[ ! -f "${kernel_path}/config-bottlerocket-hardening" ]]; then
            echo "❌ Missing config-bottlerocket-hardening"
            ((++errors))
            continue
        fi
        if ((with_lkrg)) && [[ ! -f "${kernel_path}/config-bottlerocket-lkrg" ]]; then
            echo "❌ Missing config-bottlerocket-lkrg"
            ((++errors))
            continue
        fi
        local config_filename
        if ((with_lkrg)); then
            config_filename=$(get_kernel_config_file_name "${majorminor}" "${arch}" "lkrg")
        else
            config_filename=$(get_kernel_config_file_name "${majorminor}" "${arch}")
        fi
        if [[ ! -f "${kernel_path}/${config_filename}" ]]; then
            echo "❌ Missing ${config_filename}"
            ((++errors))
            continue
        fi

        # Extract config lines (ignoring comments by default to avoid issues with removed kernel options)
        local common_configs
        common_configs=$(grep "^CONFIG_" "${kernel_path}/config-bottlerocket" | sort -u)
        local arch_configs
        arch_configs=$(grep "^CONFIG_" "${kernel_path}/config-bottlerocket-${arch}" | sort -u)
        local full_configs
        full_configs=$(grep "^CONFIG_" "${kernel_path}/${config_filename}" | sort -u)
        local lkrg_configs=""
        if ((with_lkrg)); then
            lkrg_configs=$(grep "^CONFIG_" "${kernel_path}/config-bottlerocket-lkrg" | sort -u)
        fi
        local hardening_disabled_configs
        hardening_disabled_configs=$(sed -n 's/^# \(CONFIG_[^ ]*\) is not set$/\1/p' "${kernel_path}/config-bottlerocket-hardening" | sort)

        # Check common configs
        local missing_common
        missing_common=$(comm -23 <(echo "$common_configs") <(echo "$full_configs"))
        # Check arch-specific configs
        local missing_arch
        missing_arch=$(comm -23 <(echo "$arch_configs") <(echo "$full_configs"))
        local missing_lkrg=""
        if ((with_lkrg)); then
            missing_lkrg=$(comm -23 <(echo "$lkrg_configs") <(echo "$full_configs"))
        fi

        if [[ -n "$missing_common" ]]; then
            echo "❌ Missing common configs:"
            echo "$missing_common"
            ((++errors))
        fi

        if [[ -n "$missing_arch" ]]; then
            echo "❌ Missing arch-specific configs:"
            echo "$missing_arch"
            ((++errors))
        fi

        if [[ -n "$missing_lkrg" ]]; then
            echo "❌ Missing LKRG configs:"
            echo "$missing_lkrg"
            ((++errors))
        fi

        local hardening_violations=""
        while IFS= read -r disabled_config; do
            if ((with_lkrg)); then
                case "${disabled_config}" in
                CONFIG_MODULES | CONFIG_MODULE_SIG | CONFIG_MODULE_UNLOAD)
                    continue
                    ;;
                esac
            fi
            if [[ -n "${disabled_config}" ]] && grep -q "^${disabled_config}=" "${kernel_path}/${config_filename}"; then
                hardening_violations+="${disabled_config}"$'\n'
            fi
        done <<< "${hardening_disabled_configs}"

        if [[ -n "$hardening_violations" ]]; then
            echo "❌ Hardening configs unexpectedly enabled:"
            echo "$hardening_violations"
            ((++errors))
        fi

        local loadable_module_configs=""
        if ((with_lkrg)); then
            loadable_module_configs=$(grep "^CONFIG_.*=m$" "${kernel_path}/${config_filename}" || true)
            if [[ -n "${loadable_module_configs}" ]]; then
                echo "❌ Non-LKRG loadable module configs unexpectedly enabled:"
                echo "${loadable_module_configs}"
                ((++errors))
            fi
        fi

        if [[ -z "$missing_common" && -z "$missing_arch" && -z "$missing_lkrg" && -z "$hardening_violations" && -z "$loadable_module_configs" ]]; then
            echo "✅ All configs present for ${arch}"
        fi
    done

    if ((errors == 0)); then
        echo -e "\n🎉 All kernel config validations passed!"
    else
        echo -e "\n💥 Some kernel config validations failed!"
        bail "Kernel configuration validation failed"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
        usage
        exit 0
        ;;
    --kernel)
        if [[ $# -lt 2 ]]; then
            bail "--kernel requires a kernel major.minor value"
        fi
        kernel_filter=$(normalize_kernel_filter "$2")
        shift 2
        ;;
    --kernel=*)
        kernel_filter=$(normalize_kernel_filter "${1#--kernel=}")
        shift
        ;;
    --with-lkrg)
        with_lkrg=1
        shift
        ;;
    --without-lkrg)
        with_lkrg=0
        shift
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

if ((with_lkrg)); then
    if [[ -n "${kernel_filter}" && "${kernel_filter}" != "6.18" ]]; then
        bail "--with-lkrg is only supported for kernel 6.18"
    fi
    kernel_filter="6.18"
fi

# Ensure this script is run within the Bottlerocket SDK container
if [[ ! -d "${KERNEL_KIT_DIR}" ]]; then
    usage
    bail
fi

# Guarantee that at least the kernel sources provided by the kernels are available
# to generate the configuration.
fetch_sources

# Process kernels with available RPMs
found_any_rpm=0
for kernel_dir in "${KERNEL_KIT_DIR}/packages"/kernel-*; do
    if [[ ! -d "${kernel_dir}" ]]; then
        bail "No Kernel directory found for ${kernel_dir}"
    fi
    kernel_dir_selected "${kernel_dir}" || continue

    kernel_pkg=$(basename "${kernel_dir}")
    # Multiple RPMs can coexist. Use version sorting to select the latest RPM.
    rpm_file=$(find "${kernel_dir}" -name "kernel*.src.rpm" | sort -V | tail -1)

    if [[ -z "${rpm_file}" ]]; then
        echo "No RPM found for ${kernel_pkg}, skipping"
        continue
    fi

    found_any_rpm=$((found_any_rpm + 1))

    echo "Processing ${kernel_pkg}: $(basename "${rpm_file}")"

    tmpdir=$(mktemp -d)
    pushd "${tmpdir}" || bail "Unable to enter temporary directory"

    cp "${rpm_file}" kernel-source.rpm

    version="$(rpm --query --nosignature --queryformat '%{VERSION}' kernel-source.rpm)"
    majorminor=${version%.*}

    merge_kernel_configs "${version}" "${majorminor}" "${tmpdir}" || bail "Failed to merge kernel config for ${kernel_pkg}"

    echo "Validating ${kernel_pkg} configurations..."
    validate_kernel_configs "${version}" "${majorminor}" || bail "Validation failed for ${kernel_pkg}"

    popd || bail "Could not return from temporary directory"
done

# Check if we found any RPMs at all
if [ "${found_any_rpm}" -eq 0 ]; then
    if [[ -n "${kernel_filter}" ]]; then
        bail "No kernel RPMs found for kernel-${kernel_filter}"
    else
        bail "No kernel RPMs found in any directory"
    fi
fi
