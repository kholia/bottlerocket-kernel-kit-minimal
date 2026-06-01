#!/usr/bin/env bash
set -e -o pipefail

bail() {
    if [[ $# -gt 0 ]]; then
        >&2 echo "Error: $*"
    fi
    exit 1
}

find_sdk() {
  grep -A5 '^\[sdk\]' Twoliter.lock | grep '^source' | cut -d'"' -f2
}

default_docker_platform() {
  case "$(uname -m)" in
    x86_64)
      echo "linux/amd64"
      ;;
    aarch64|arm64)
      echo "linux/arm64"
      ;;
  esac
}

SCRIPT_PATH="$1"
shift

if [[ -z "${SDK_PLATFORM}" ]]; then
  SDK_PLATFORM="$(default_docker_platform)"
fi

docker_platform_args=()
if [[ -n "${SDK_PLATFORM}" ]]; then
  docker_platform_args=(--platform "${SDK_PLATFORM}")
fi

if [[ -z "${SDK}" ]]; then
  echo "Retrieving SDK from Twoliter.lock"
  SDK="$(find_sdk)"
fi

echo "Using SDK: ${SDK} to run the provided script"
if [[ -n "${SDK_PLATFORM}" ]]; then
  echo "Using Docker platform: ${SDK_PLATFORM}"
fi

docker run --rm \
    "${docker_platform_args[@]}" \
    -v "$(pwd):/bottlerocket-kernel-kit" \
    --user "$(id -u):$(id -g)" \
    "${SDK}" \
    bash "${SCRIPT_PATH}" "$@"
