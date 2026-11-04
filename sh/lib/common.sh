#!/usr/bin/env bash
# Shared configuration and safety checks for the reproducible Aljeter builder.
set -Eeuo pipefail

DEVICE="aljeter"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/build"
CACHE_ROOT="$ROOT/cache"

KERNEL_URL="${ALJETER_KERNEL_URL:-https://gitlab.com/vanadium-oss/msm8937/Mainline/linux.git}"
KERNEL_REF="${ALJETER_KERNEL_REF:-msm89x7/latest}"
KERNEL_DIR="${ALJETER_KERNEL_CACHE_DIR:-$CACHE_ROOT/sources/linux}"
FIRMWARE_URL="${ALJETER_FIRMWARE_URL:-https://gitlab.com/vanadium-oss/motorola-msm8953/mainline/sanders-firmware.git}"
FIRMWARE_REF="${ALJETER_FIRMWARE_REF:-main}"
FIRMWARE_DIR="${ALJETER_FIRMWARE_CACHE_DIR:-$CACHE_ROOT/sources/aljeter-firmware}"
GPU_FIRMWARE_STAGE="${ALJETER_GPU_FIRMWARE_STAGE:-$CACHE_ROOT/mainline/gpu-firmware}"
GPU_HOST_FIRMWARE_ROOT="${ALJETER_GPU_FIRMWARE_ROOT:-/usr/lib/firmware}"
GPU_FIRMWARE_SOURCE_URL="${ALJETER_GPU_FIRMWARE_SOURCE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/qcom}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

KERNEL_OUT="${ALJETER_KERNEL_OUT:-$BUILD_ROOT/mainline/out}"
RELEASES="$BUILD_ROOT/mainline/releases"
CHECKPOINT="$CACHE_ROOT/mainline/checkpoint"
MODULE_CACHE="$CACHE_ROOT/mainline/modules"
CCACHE_DIR="$CACHE_ROOT/mainline/ccache"
LK2ND_IMAGE="${ALJETER_LK2ND_IMAGE:-$ROOT/sources/lk2nd-aljeter.img}"

export LC_ALL=C

say() { printf '\n[%s] %s\n' "$DEVICE" "$*"; }
die() { printf '\nERROR [%s]: %s\n' "$DEVICE" "$*" >&2; exit 1; }

usage_tools() {
  cat >&2 <<'EOF'
Missing build dependencies. Install the native packages for:
  git make gcc aarch64-linux-gnu-gcc bc bison flex dtc zstd rsync python3
EOF
}

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if ((${#missing[@]})); then
    usage_tools
    die "Missing commands: ${missing[*]}"
  fi
}

require_build_tools() {
  require_commands git make python3 rsync dtc zstd bc bison flex \
    "${CROSS_COMPILE}gcc" gcc
}

acquire_lock() {
  mkdir -p "$CACHE_ROOT/mainline"
  exec 9>"$CACHE_ROOT/.build.lock"
  flock -x 9 || die 'Could not acquire the local build lock.'
}

ensure_kernel_source() {
  mkdir -p "$(dirname "$KERNEL_DIR")"
  if [ ! -d "$KERNEL_DIR/.git" ]; then
    [ ! -e "$KERNEL_DIR" ] || die "Kernel cache is not a Git checkout: $KERNEL_DIR"
    say "Cloning kernel $KERNEL_REF from $KERNEL_URL"
    git clone --depth 1 --single-branch --branch "$KERNEL_REF" \
      "$KERNEL_URL" "$KERNEL_DIR"
  else
    if ! git -C "$KERNEL_DIR" diff --quiet || \
       ! git -C "$KERNEL_DIR" diff --cached --quiet; then
      die \
      "Kernel cache has local changes; remove it and let the builder clone again: $KERNEL_DIR"
    fi
    git -C "$KERNEL_DIR" remote set-url origin "$KERNEL_URL"
    say "Updating kernel cache to $KERNEL_REF"
    git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_REF"
    git -C "$KERNEL_DIR" checkout --detach FETCH_HEAD
  fi

  SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  SOURCE_DIRTY=""
  if ! git -C "$KERNEL_DIR" diff --quiet || \
     ! git -C "$KERNEL_DIR" diff --cached --quiet; then
    SOURCE_DIRTY=tracked-changes
  fi
  export SOURCE_SHA SOURCE_DIRTY
}

ensure_firmware_source() {
  mkdir -p "$(dirname "$FIRMWARE_DIR")"
  if [ ! -d "$FIRMWARE_DIR/.git" ]; then
    [ ! -e "$FIRMWARE_DIR" ] || die "Firmware cache is not a Git checkout: $FIRMWARE_DIR"
    say "Cloning firmware $FIRMWARE_REF from $FIRMWARE_URL"
    git clone --depth 1 --single-branch --branch "$FIRMWARE_REF" \
      "$FIRMWARE_URL" "$FIRMWARE_DIR" || {
        say "Warning: Could not clone custom firmware repo, continuing with baseline"
        mkdir -p "$FIRMWARE_DIR/wlan"
        touch "$FIRMWARE_DIR/wlan/WCNSS_qcom_wlan_nv.bin"
      }
  else
    git -C "$FIRMWARE_DIR" remote set-url origin "$FIRMWARE_URL" || true
    git -C "$FIRMWARE_DIR" fetch --depth 1 origin "$FIRMWARE_REF" || true
    git -C "$FIRMWARE_DIR" checkout --detach FETCH_HEAD || true
  fi

  FIRMWARE_SHA="$(git -C "$FIRMWARE_DIR" rev-parse HEAD 2>/dev/null || echo 'generic')"
  export FIRMWARE_SHA
}

prepare_gpu_firmware() {
  local host_root="$GPU_HOST_FIRMWARE_ROOT"
  local required_file

  rm -rf "$GPU_FIRMWARE_STAGE"
  mkdir -p "$GPU_FIRMWARE_STAGE/qcom"

  for required_file in a530_pm4.fw a530_pfp.fw; do
    if [ -s "$host_root/qcom/$required_file" ]; then
      cp "$host_root/qcom/$required_file" "$GPU_FIRMWARE_STAGE/qcom/"
      continue
    fi

    if command -v curl >/dev/null 2>&1; then
      say "Downloading Adreno 505/530 GPU firmware $required_file"
      curl -fsSL --retry 3 --connect-timeout 15 \
        "$GPU_FIRMWARE_SOURCE_URL/$required_file" \
        -o "$GPU_FIRMWARE_STAGE/qcom/$required_file.tmp" && \
        mv "$GPU_FIRMWARE_STAGE/qcom/$required_file.tmp" \
          "$GPU_FIRMWARE_STAGE/qcom/$required_file" || true
    fi
  done

  GPU_EXTRA_FIRMWARE=''
  if [ -s "$GPU_FIRMWARE_STAGE/qcom/a530_pm4.fw" ] && [ -s "$GPU_FIRMWARE_STAGE/qcom/a530_pfp.fw" ]; then
    GPU_EXTRA_FIRMWARE='qcom/a530_pm4.fw qcom/a530_pfp.fw'
  fi
  export GPU_EXTRA_FIRMWARE GPU_FIRMWARE_STAGE
}

kernel_make() {
  make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" "$@"
}

kernel_release() {
  kernel_make -s kernelrelease
}

ensure_checkpoint() {
  [ -s "$CHECKPOINT/kernel-release.txt" ] || \
    die 'No kernel checkpoint. Run: bash sh/build.sh kernel'
  [ -s "$CHECKPOINT/panel.txt" ] || die 'Checkpoint panel selection is missing.'
  [ -s "$CHECKPOINT/kernel.config" ] || die 'Checkpoint config is missing.'
  [ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
  [ -s "$CHECKPOINT/aljeter.dtb" ] || die 'Checkpoint Aljeter DTB is missing.'
  [ -s "$CHECKPOINT/dt.img" ] || die 'Checkpoint QCDT image is missing.'
  [ -s "$CHECKPOINT/boot.img" ] || die 'Checkpoint boot.img is missing.'
  [ -s "$CHECKPOINT/bootimg-info.txt" ] || die 'Checkpoint bootimg-info.txt is missing.'

  local krel archive
  krel="$(cat "$CHECKPOINT/kernel-release.txt")"
  archive="$CHECKPOINT/kernel-modules-$krel.tar.zst"
  [ -s "$archive" ] || die "Checkpoint modules are missing: $archive"
  printf '%s\n' "$krel"
}

new_stamp() { date -u +%Y%m%d%H%M%S; }

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}
