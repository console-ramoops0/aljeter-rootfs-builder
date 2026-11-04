#!/usr/bin/env bash
# Clone, build and publish the Aljeter kernel with checked artifacts.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: bash sh/mainline/build.sh [OPTION]

Clones and builds:
  $KERNEL_URL

The checkout is cached at:
  $KERNEL_DIR

Expected branch:
  $KERNEL_REF

Options:
  --reuse  validate the last checkpoint without compiling
  --clean  discard only the generated kernel output and rebuild
  --help   show this help

Overrides:
  ALJETER_KERNEL_URL, ALJETER_KERNEL_REF, ALJETER_KERNEL_CACHE_DIR,
  ALJETER_KERNEL_OUT, JOBS,
  ALJETER_GPU_FIRMWARE_ROOT, ALJETER_GPU_FIRMWARE_STAGE,
  ALJETER_GPU_FIRMWARE_SOURCE_URL,
  ALJETER_BOOT_CMDLINE, ALJETER_LK2ND_IMAGE,
  ALJETER_KERNEL_DEBUG_INFO (default: 0)
EOF
}

mode="build"
case "${1:-}" in
  '') ;;
  --reuse) mode="reuse" ;;
  --clean) mode="clean" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

require_build_tools
acquire_lock
ensure_kernel_source

# Fix missing header in net/qrtr/smd.c if present in the tree
if [ -f "$KERNEL_DIR/net/qrtr/smd.c" ] && \
   grep -q "qcom_smd_qrtr_uevent" "$KERNEL_DIR/net/qrtr/smd.c" 2>/dev/null && \
   ! grep -q "linux/mod_devicetable.h" "$KERNEL_DIR/net/qrtr/smd.c" 2>/dev/null; then
  say "Applying missing <linux/mod_devicetable.h> include to net/qrtr/smd.c"
  sed -i '/#include <linux\/soc\/qcom\/qrtr.h>/a #include <linux/mod_devicetable.h>' "$KERNEL_DIR/net/qrtr/smd.c"
fi

# Fix missing newline in drivers/soc/qcom/Makefile if present
if [ -f "$KERNEL_DIR/drivers/soc/qcom/Makefile" ] && \
   grep -q "qcom_sns_reg.oobj-" "$KERNEL_DIR/drivers/soc/qcom/Makefile" 2>/dev/null; then
  say "Applying missing newline fix in drivers/soc/qcom/Makefile"
  sed -i 's/qcom_sns_reg.oobj-/qcom_sns_reg.o\nobj-/' "$KERNEL_DIR/drivers/soc/qcom/Makefile"
fi

ensure_firmware_source
prepare_gpu_firmware
[ -s "$LK2ND_IMAGE" ] || die "LK2ND image not found: $LK2ND_IMAGE"

KEEP_DEBUG_INFO="${ALJETER_KERNEL_DEBUG_INFO:-0}"
case "$KEEP_DEBUG_INFO" in
  0|1) ;;
  *) die 'ALJETER_KERNEL_DEBUG_INFO must be 0 or 1.' ;;
esac

if [ "$mode" = reuse ]; then
  KREL="$(ensure_checkpoint)"
  say "Checkpoint OK: kernel $KREL"
  exit 0
fi

if [ "$mode" = clean ]; then
  rm -rf "$KERNEL_OUT"
fi
mkdir -p "$KERNEL_OUT" "$RELEASES" "$MODULE_CACHE" "$CCACHE_DIR"

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR
  ccache --max-size "${CCACHE_MAXSIZE:-2G}" >/dev/null
  export CC="ccache ${CROSS_COMPILE}gcc"
fi

ALJETER_CONFIG="$ROOT/sources/mainline/aljeter.config"
CONTAINER_CONFIG="$ROOT/sources/mainline/coolify-containers.config"
PANEL_NAME='automatic (lk2nd + motorola panels)'
PANEL_DTB_TARGET='qcom/msm8937-motorola-aljeter.dtb'
PANEL_DTB_FILE='msm8937-motorola-aljeter.dtb'

say "Generating Aljeter kernel configuration from defconfig + fragments"
kernel_make defconfig

CONFIG_FRAGMENTS=()
[ -s "$ALJETER_CONFIG" ] && CONFIG_FRAGMENTS+=("$ALJETER_CONFIG")
[ -s "$CONTAINER_CONFIG" ] && CONFIG_FRAGMENTS+=("$CONTAINER_CONFIG")

if [ ${#CONFIG_FRAGMENTS[@]} -gt 0 ]; then
  "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -Q -O "$KERNEL_OUT" \
    "$KERNEL_OUT/.config" "${CONFIG_FRAGMENTS[@]}"
fi
kernel_make olddefconfig

KCONFIG_TOOL="$KERNEL_DIR/scripts/config"
[ -s "$KCONFIG_TOOL" ] || die "Kernel config helper is missing: $KCONFIG_TOOL"

if [ -n "${GPU_EXTRA_FIRMWARE:-}" ]; then
  say "Embedding Adreno GPU firmware for early boot"
  bash "$KCONFIG_TOOL" --file "$KERNEL_OUT/.config" \
    --set-str CONFIG_EXTRA_FIRMWARE "$GPU_EXTRA_FIRMWARE" \
    --set-str CONFIG_EXTRA_FIRMWARE_DIR "$GPU_FIRMWARE_STAGE"
  kernel_make olddefconfig
fi

if [ "$KEEP_DEBUG_INFO" -eq 0 ]; then
  say 'Disabling build-only kernel DWARF information'
  bash "$KCONFIG_TOOL" --file "$KERNEL_OUT/.config" \
    --disable CONFIG_DEBUG_INFO \
    --disable CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
    --disable CONFIG_DEBUG_INFO_REDUCED \
    --disable CONFIG_DEBUG_INFO_COMPRESSED_NONE \
    --disable CONFIG_DEBUG_INFO_BTF
  kernel_make olddefconfig
fi

say "Compiling kernel, $PANEL_NAME DTB and modules with $JOBS jobs"
kernel_make -j"$JOBS" Image.gz modules dtbs

KREL="$(kernel_release)"
BOOT_DIR="$KERNEL_OUT/arch/$ARCH/boot"
DTB_DIR="$BOOT_DIR/dts/qcom"
IMAGE="$BOOT_DIR/Image.gz"
DTB="$DTB_DIR/$PANEL_DTB_FILE"
QCDT_TOOL="$ROOT/sh/mainline/make-qcdt.py"
BOOTIMG_TOOL="$ROOT/sh/mainline/make-bootimg-qcdt.py"
[[ -f "$QCDT_TOOL" ]] || die "QCDT generator missing: $QCDT_TOOL"
[[ -f "$BOOTIMG_TOOL" ]] || die "boot image generator missing: $BOOTIMG_TOOL"
for artifact in "$IMAGE" "$DTB" "$KERNEL_OUT/System.map" "$KERNEL_OUT/vmlinux"; do
  [ -s "$artifact" ] || die "Kernel artifact missing: $artifact"
done

STAGE="$CACHE_ROOT/mainline/.stage-$$"
MODULES_STAGE="$CACHE_ROOT/mainline/.modules-stage-$$"
rm -rf "$STAGE" "$MODULES_STAGE"
mkdir -p "$STAGE" "$MODULES_STAGE"
trap 'rm -rf "$STAGE" "$MODULES_STAGE"' EXIT

say "Installing modules for kernel $KREL into a staging directory"
kernel_make modules_install INSTALL_MOD_PATH="$MODULES_STAGE" INSTALL_MOD_STRIP=1
MODULE_ARCHIVE="$STAGE/kernel-modules-$KREL.tar.zst"
tar -C "$MODULES_STAGE" -I zstd -cf "$MODULE_ARCHIVE" "lib/modules/$KREL"
rm -rf "$MODULES_STAGE"

cp "$IMAGE" "$STAGE/Image.gz"
cp "$DTB" "$STAGE/aljeter.dtb"
cp "$LK2ND_IMAGE" "$STAGE/lk2nd.img"
cp "$KERNEL_OUT/.config" "$STAGE/kernel.config"
cp "$KERNEL_OUT/System.map" "$STAGE/System.map"
cp "$KERNEL_OUT/vmlinux" "$STAGE/vmlinux"
printf '%s\n' "$KREL" > "$STAGE/kernel-release.txt"
printf '%s\n' auto > "$STAGE/panel.txt"

say "Creating Qualcomm QCDT tables for lk2nd"
python3 "$QCDT_TOOL" "$STAGE/dt.img" "$STAGE/aljeter.dtb"

cat "$IMAGE" "$DTB" > "$STAGE/Image.gz-dtb"

BOOT_ROOT="${ALJETER_BOOT_ROOT:-PARTLABEL=userdata}"
BOOT_CMDLINE="${ALJETER_BOOT_CMDLINE:-console=tty0 console=ttyMSM0,115200 root=$BOOT_ROOT rootfstype=ext4 rw rootwait panic=10 fsck.repair=yes lpm_levels.sleep_disabled=1 clk_ignore_unused pd_ignore_unused net.ifnames=0 rootdelay=5}"
BOOT_IMAGE="$STAGE/boot.img"

say "Creating Android boot images for Aljeter (MSM8937)"
make_boot_image() {
  local kernel_image="$1" dt_image="$2" output_image="$3"

  python3 "$BOOTIMG_TOOL" \
    --kernel "$kernel_image" \
    --qcdt "$dt_image" \
    --base 0x80000000 \
    --kernel-offset 0x8000 \
    --ramdisk-offset 0x01000000 \
    --tags-offset 0x00000100 \
    --pagesize 2048 \
    --board "aljeter" \
    --cmdline "$BOOT_CMDLINE" \
    --output "$output_image"

  [ "$(dd if="$output_image" bs=1 count=8 2>/dev/null)" = 'ANDROID!' ] || \
    die "mkbootimg produced an invalid image: $output_image"
  local image_size
  image_size="$(stat -c '%s' "$output_image")"
  [ "$image_size" -le 16777216 ] || die \
    "$output_image is ${image_size} bytes; Aljeter boot partition is 16777216 bytes."
}

make_boot_image "$STAGE/Image.gz" "$STAGE/dt.img" "$BOOT_IMAGE"
make_boot_image "$STAGE/Image.gz-dtb" "$STAGE/dt.img" "$STAGE/boot-dtb.img"

cat > "$STAGE/bootimg-info.txt" <<EOF
format=android-bootimg-v0
bootimg_tool=$BOOTIMG_TOOL
kernel=Image.gz
ramdisk=none
dtb=dt.img (QCDT v2, selected by lk2nd)
pagesize=2048
base=0x80000000
kernel_offset=0x00008000
ramdisk_offset=0x01000000
tags_offset=0x00000100
board=aljeter
cmdline=$BOOT_CMDLINE
target_boot_partition_bytes=16777216
EOF

STAMP="$(new_stamp)"
BUILD_DIR="$RELEASES/kernel-$KREL-$STAMP"
mkdir -p "$BUILD_DIR"
cp -a "$STAGE/." "$BUILD_DIR/"

rm -rf "$CHECKPOINT"
mkdir -p "$CHECKPOINT"
cp -a "$STAGE/." "$CHECKPOINT/"

say "Published kernel $KREL to $BUILD_DIR"
say "Kernel checkpoint updated at $CHECKPOINT"
