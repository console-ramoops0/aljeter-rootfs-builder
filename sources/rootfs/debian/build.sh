#!/usr/bin/env bash
# Build a minimal Debian arm64 rootfs and embed the validated Aljeter kernel.
set -Eeuo pipefail

: "${ROOT:?rootfs runner did not export ROOT}"
: "${BUILD_ROOT:?rootfs runner did not export BUILD_ROOT}"
: "${CACHE_ROOT:?rootfs runner did not export CACHE_ROOT}"
: "${CHECKPOINT:?rootfs runner did not export CHECKPOINT}"
: "${KERNEL_RELEASE:?rootfs runner did not export KERNEL_RELEASE}"
: "${KERNEL_MODULES_ARCHIVE:?rootfs runner did not export KERNEL_MODULES_ARCHIVE}"
: "${KERNEL_CONFIG_FILE:?rootfs runner did not export KERNEL_CONFIG_FILE}"
: "${KERNEL_SYSTEM_MAP_FILE:?rootfs runner did not export KERNEL_SYSTEM_MAP_FILE}"

say() { printf '\n[debian] %s\n' "$*"; }
die() { printf '\nERROR [debian]: %s\n' "$*" >&2; exit 1; }

PROFILE="$ROOT/sources/rootfs/debian/profile.sh"
[ -r "$PROFILE" ] || die "Debian profile is missing: $PROFILE"
source "$PROFILE"

SUITE="$ALJETER_DEBIAN_SUITE"
ARCH="$ALJETER_DEBIAN_ARCH"
MIRROR="$ALJETER_DEBIAN_MIRROR"
COMPONENTS="$ALJETER_DEBIAN_COMPONENTS"
PACKAGES="$ALJETER_DEBIAN_PACKAGES"
IMAGE_SIZE_MIB="$ALJETER_DEBIAN_IMAGE_SIZE_MIB"
MIN_FREE_MIB="$ALJETER_DEBIAN_MIN_FREE_MIB"
ROOTFS_LABEL="$ALJETER_ROOTFS_LABEL"
TIMEZONE="$ALJETER_TIMEZONE"
NTP_SERVERS="$ALJETER_NTP_SERVERS"
FALLBACK_NTP_SERVERS="$ALJETER_FALLBACK_NTP_SERVERS"
NTP_ROOT_DISTANCE_MAX_SEC="$ALJETER_NTP_ROOT_DISTANCE_MAX_SEC"
INCLUDE_GENERIC_QCOM_FIRMWARE="$ALJETER_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE"
: "${FIRMWARE_SOURCE_DIR:?rootfs runner did not export FIRMWARE_SOURCE_DIR}"
: "${FIRMWARE_REPOSITORY_URL:?rootfs runner did not export FIRMWARE_REPOSITORY_URL}"
: "${FIRMWARE_REF:?rootfs runner did not export FIRMWARE_REF}"
: "${FIRMWARE_SHA:?rootfs runner did not export FIRMWARE_SHA}"

OUT_DIR="$BUILD_ROOT/rootfs/debian"
WORK_ROOT="$CACHE_ROOT/rootfs/debian"
ROOTFS_DIR="$WORK_ROOT/rootfs"
STAGE="$WORK_ROOT/.stage-$$"
RELEASES="$OUT_DIR/releases"
OVERLAY_DIR="$ROOT/sources/rootfs/debian/overlay"

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) || die "Missing Debian rootfs tools: ${missing[*]}"
}

require_commands mmdebstrap qemu-aarch64-static rsync tar zstd \
  mkfs.ext4 e2fsck tune2fs blkid truncate sha256sum openssl
sudo -n true 2>/dev/null || die 'Passwordless sudo is required for ext4 image creation.'
[ "$ARCH" = arm64 ] || die "Only arm64 Debian rootfs is supported; got $ARCH."

MMDEBSTRAP_MODE="${ALJETER_MMDEBSTRAP_MODE:-root}"
case "$MMDEBSTRAP_MODE" in
  root)
    sudo -n true 2>/dev/null || die 'Passwordless sudo is required for ALJETER_MMDEBSTRAP_MODE=root.'
    ;;
  *)
    die "Unsupported ALJETER_MMDEBSTRAP_MODE: $MMDEBSTRAP_MODE (use root)."
    ;;
esac

[ -s "$KERNEL_MODULES_ARCHIVE" ] || die "Kernel modules archive is missing: $KERNEL_MODULES_ARCHIVE"
[ -s "$KERNEL_CONFIG_FILE" ] || die "Kernel config is missing: $KERNEL_CONFIG_FILE"
[ -s "$KERNEL_SYSTEM_MAP_FILE" ] || die "Kernel System.map is missing: $KERNEL_SYSTEM_MAP_FILE"
[ -d "$OVERLAY_DIR" ] || die "Runtime overlay is missing: $OVERLAY_DIR"

for overlay_file in \
  etc/hosts \
  etc/fstab \
  etc/modprobe.d/aljeter.conf \
  etc/modules-load.d/aljeter.conf \
  etc/systemd/zram-generator.conf \
  etc/NetworkManager/conf.d/99-usb0-unmanaged.conf \
  etc/ssh/sshd_config.d/90-aljeter-root.conf \
  etc/systemd/system/aljeter-ssh-hostkeys.service \
  etc/systemd/system/aljeter-time-sync.service \
  etc/systemd/system/aljeter-grow-rootfs.service \
  etc/systemd/system/usb-gadget.service \
  usr/local/sbin/usb-gadget.sh \
  usr/local/sbin/aljeter-time-sync \
  usr/local/sbin/aljeter-grow-rootfs; do
  [ -f "$OVERLAY_DIR/$overlay_file" ] || die \
    "Runtime overlay file is missing: $OVERLAY_DIR/$overlay_file"
done
[ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
[ -s "$CHECKPOINT/aljeter.dtb" ] || die 'Checkpoint Aljeter DTB is missing.'

case "$SUITE" in
  bookworm|trixie|stable|testing) ;;
  *) die "Unsupported Debian suite: $SUITE" ;;
esac

normalize_rootfs_symlinks() {
  local link target normalized
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    case "$target" in
      "$ROOTFS_DIR"/*)
        normalized="/${target#"$ROOTFS_DIR"/}"
        rm -f "$link"
        ln -s "$normalized" "$link"
        ;;
    esac
  done < <(find "$ROOTFS_DIR" -type l -print0)
}

audit_rootfs_symlinks() {
  local link target
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    case "$target" in
      "$ROOTFS_DIR"/*)
        die "Host path leaked into rootfs symlink: $link -> $target"
        ;;
    esac
  done < <(find "$ROOTFS_DIR" -type l -print0)
}

install_runtime_overlay() {
  say 'Installing Aljeter runtime overlay'
  rsync -a "$OVERLAY_DIR/" "$ROOTFS_DIR/"
  chmod 0755 "$ROOTFS_DIR/usr/local/sbin/usb-gadget.sh" \
    "$ROOTFS_DIR/usr/local/sbin/aljeter-time-sync" \
    "$ROOTFS_DIR/usr/local/sbin/aljeter-grow-rootfs"

  mkdir -p \
    "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d" \
    "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants" \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"

  cat > "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d/aljeter.conf" <<EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=$FALLBACK_NTP_SERVERS
RootDistanceMaxSec=$NTP_ROOT_DISTANCE_MAX_SEC
EOF

  ln -sfn /lib/systemd/system/systemd-timesyncd.service \
    "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
  ln -sfn ../usb-gadget.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
  ln -sfn ../aljeter-ssh-hostkeys.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/aljeter-ssh-hostkeys.service"
  ln -sfn ../aljeter-time-sync.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/aljeter-time-sync.service"
  ln -sfn ../aljeter-grow-rootfs.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/aljeter-grow-rootfs.service"
  ln -sfn /lib/systemd/system/NetworkManager.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/NetworkManager.service" || true
  ln -sfn /lib/systemd/system/haveged.service \
    "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/haveged.service" || true
}

configure_root_password() {
  say 'Configuring root and user passwords'
  local root_password_hash
  root_password_hash="$(printf '%s' "$ALJETER_ROOT_PASSWORD" | openssl passwd -6 -stdin)"
  awk -F: -v hash="$root_password_hash" 'BEGIN { OFS=FS } $1 == "root" { $2 = hash } { print }' \
    "$ROOTFS_DIR/etc/shadow" > "$ROOTFS_DIR/etc/shadow.new"
  mv "$ROOTFS_DIR/etc/shadow.new" "$ROOTFS_DIR/etc/shadow"
  ln -sfn /lib/systemd/system/ssh.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
}

configure_timezone() {
  say "Configuring timezone $TIMEZONE"
  ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOTFS_DIR/etc/localtime"
  printf '%s\n' "$TIMEZONE" > "$ROOTFS_DIR/etc/timezone"
}

mkdir -p "$OUT_DIR" "$RELEASES" "$WORK_ROOT"
sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"
mkdir -p "$ROOTFS_DIR" "$STAGE"
trap 'sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"' EXIT

say "Bootstrapping Debian $SUITE/$ARCH with $MMDEBSTRAP_MODE + qemu"
sudo -n mmdebstrap \
  --mode="$MMDEBSTRAP_MODE" \
  --format=directory \
  --architectures="$ARCH" \
  --variant=minbase \
  --components="$COMPONENTS" \
  --include="$PACKAGES" \
  --skip=check/qemu \
  --setup-hook='mkdir -p "$1/usr/libexec/qemu-binfmt" && cp /usr/bin/qemu-aarch64-static "$1/usr/libexec/qemu-binfmt/aarch64-binfmt-P" && chmod 0755 "$1/usr/libexec/qemu-binfmt/aarch64-binfmt-P"' \
  --aptopt='Acquire::Languages "none"' \
  --aptopt='APT::Install-Recommends "false"' \
  --aptopt='APT::Install-Suggests "false"' \
  "$SUITE" "$ROOTFS_DIR" "$MIRROR"

sudo -n chown -R "$(id -u):$(id -g)" "$ROOTFS_DIR"

say "Normalizing rootfs symlinks"
normalize_rootfs_symlinks
audit_rootfs_symlinks

say "Embedding kernel $KERNEL_RELEASE"
mkdir -p "$ROOTFS_DIR/boot" "$ROOTFS_DIR/etc/modprobe.d" "$ROOTFS_DIR/etc/systemd/system"
tar -I zstd -xf "$KERNEL_MODULES_ARCHIVE" -C "$ROOTFS_DIR" --no-same-owner

for MODULE_LINK in \
  "$ROOTFS_DIR/usr/lib/modules/$KERNEL_RELEASE/build" \
  "$ROOTFS_DIR/usr/lib/modules/$KERNEL_RELEASE/source"; do
  [ ! -L "$MODULE_LINK" ] || rm -f "$MODULE_LINK"
done
audit_rootfs_symlinks

# Install Aljeter firmware (WCNSS, Wi-Fi, GPU, DSP)
say "Installing Aljeter firmware"
mkdir -p "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8937/motorola/aljeter" \
         "$ROOTFS_DIR/usr/lib/firmware/wlan/prima" \
         "$ROOTFS_DIR/usr/lib/firmware/qcom"

# 1. WLAN NVRAM and config files
if [ -d "$FIRMWARE_SOURCE_DIR/wlan" ]; then
  for wlan_file in "$FIRMWARE_SOURCE_DIR"/wlan/*; do
    [ -f "$wlan_file" ] || continue
    cp "$wlan_file" "$ROOTFS_DIR/usr/lib/firmware/wlan/prima/"
    cp "$wlan_file" "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8937/motorola/aljeter/"
  done
fi

# 2. WCNSS pronto firmware (wcnss.mdt and chunks)
if [ -d "$FIRMWARE_SOURCE_DIR/modem/image" ]; then
  for fw in "$FIRMWARE_SOURCE_DIR"/modem/image/wcnss.*; do
    [ -f "$fw" ] || continue
    cp "$fw" "$ROOTFS_DIR/usr/lib/firmware/"
    cp "$fw" "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8937/motorola/aljeter/"
  done

  # Also copy adsp, venus, modem and mba if present for DSP subsystem loading
  for fw in "$FIRMWARE_SOURCE_DIR"/modem/image/mba.mbn \
            "$FIRMWARE_SOURCE_DIR"/modem/image/modem.* \
            "$FIRMWARE_SOURCE_DIR"/modem/image/adsp.* \
            "$FIRMWARE_SOURCE_DIR"/modem/image/venus.*; do
    [ -f "$fw" ] || continue
    cp "$fw" "$ROOTFS_DIR/usr/lib/firmware/"
  done
fi

# 3. Adreno 505/530 GPU microcode
if [ -s "$ROOT/cache/mainline/gpu-firmware/qcom/a530_pm4.fw" ]; then
  cp "$ROOT/cache/mainline/gpu-firmware/qcom/a530_pm4.fw" "$ROOTFS_DIR/usr/lib/firmware/qcom/"
  cp "$ROOT/cache/mainline/gpu-firmware/qcom/a530_pfp.fw" "$ROOTFS_DIR/usr/lib/firmware/qcom/"
fi

cp "$CHECKPOINT/Image.gz" "$ROOTFS_DIR/boot/Image.gz-$KERNEL_RELEASE"
cp "$CHECKPOINT/aljeter.dtb" "$ROOTFS_DIR/boot/aljeter.dtb"
cp "$KERNEL_CONFIG_FILE" "$ROOTFS_DIR/boot/config-$KERNEL_RELEASE"
cp "$KERNEL_SYSTEM_MAP_FILE" "$ROOTFS_DIR/boot/System.map-$KERNEL_RELEASE"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/Image.gz"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/vmlinuz"

printf '%s\n' aljeter > "$ROOTFS_DIR/etc/hostname"
install_runtime_overlay
configure_root_password
configure_timezone
printf 'kernel_release=%s\n' "$KERNEL_RELEASE" > "$ROOTFS_DIR/etc/aljeter-kernel-release"

sanitize_rootfs() {
  say 'Removing build-time identities and caches'
  find "$ROOTFS_DIR/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete
  rm -f "$ROOTFS_DIR/root/.bash_history" \
    "$ROOTFS_DIR/var/lib/systemd/random-seed" \
    "$ROOTFS_DIR/var/lib/NetworkManager/secret_key" \
    "$ROOTFS_DIR/usr/bin/qemu-aarch64-static" \
    "$ROOTFS_DIR/usr/libexec/qemu-binfmt/aarch64-binfmt-P"
  : > "$ROOTFS_DIR/etc/machine-id"
  rm -f "$ROOTFS_DIR/var/lib/dbus/machine-id"
  ln -s /etc/machine-id "$ROOTFS_DIR/var/lib/dbus/machine-id"

  mkdir -p "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/var/tmp"
  for clean_dir in \
    "$ROOTFS_DIR/usr/share/doc" \
    "$ROOTFS_DIR/usr/share/man" \
    "$ROOTFS_DIR/var/cache/apt/archives" \
    "$ROOTFS_DIR/var/lib/apt/lists" \
    "$ROOTFS_DIR/var/log" \
    "$ROOTFS_DIR/tmp" \
    "$ROOTFS_DIR/var/tmp"; do
    [ -d "$clean_dir" ] || continue
    find "$clean_dir" -mindepth 1 -delete
  done
  find "$ROOTFS_DIR" -xdev -type f -name '*.pyc' -delete
  chmod 1777 "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/var/tmp"
}

sanitize_rootfs

sudo -n chown -R 0:0 "$ROOTFS_DIR"

TARBALL="$STAGE/debian-${SUITE}-${ARCH}-aljeter-$KERNEL_RELEASE.tar.zst"
IMAGE="$STAGE/debian-${SUITE}-${ARCH}-aljeter-$KERNEL_RELEASE.ext4"
INFO="$STAGE/build-info.txt"

say "Creating Debian tarball"
sudo -n tar --numeric-owner --xattrs --acls -I zstd -cf "$TARBALL" -C "$ROOTFS_DIR" .

say "Creating ${IMAGE_SIZE_MIB} MiB ext4 image"
truncate -s "${IMAGE_SIZE_MIB}M" "$IMAGE"
sudo -n mkfs.ext4 -F -m 0 -N 32768 -J size=16 -L "$ROOTFS_LABEL" -U random -d "$ROOTFS_DIR" "$IMAGE" >/dev/null
sudo -n e2fsck -fn "$IMAGE" >/dev/null

FS_STATS="$(sudo -n tune2fs -l "$IMAGE")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
FREE_MIB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))

cat > "$INFO" <<EOF
distribution=debian
suite=$SUITE
architecture=$ARCH
device=aljeter (Motorola Moto G6 Play)
kernel_release=$KERNEL_RELEASE
image_size_mib=$IMAGE_SIZE_MIB
rootfs_label=$ROOTFS_LABEL
image_free_mib=$FREE_MIB
ssh_root_password_configured=yes
default_user=root
default_password=aljeter
ip_address=172.16.42.1 (usb0)
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

STAMP="$(date -u +%Y%m%d%H%M%S)"
RELEASE="$RELEASES/debian-${SUITE}-${ARCH}-$STAMP"
mkdir -p "$RELEASE"
cp "$TARBALL" "$RELEASE/"
cp "$IMAGE" "$RELEASE/"
cp "$INFO" "$RELEASE/build-info.txt"
(cd "$RELEASE" && sha256sum -- build-info.txt *.ext4 *.tar.zst > SHA256SUMS)

if [ -L "$OUT_DIR/latest" ]; then
  rm -f -- "$OUT_DIR/latest"
fi
printf '%s\n' "$RELEASE" > "$OUT_DIR/latest"

say "Debian rootfs complete"
say "Release: $RELEASE"
say "Free ext4 space: ${FREE_MIB} MiB"
