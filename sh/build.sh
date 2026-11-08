#!/usr/bin/env bash
# Entry point for the Aljeter Debian rootfs and kernel builder.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
ALJETER MAINLINE & DEBIAN ROOTFS BUILDER (Moto G6 Play - MSM8937)

  bash sh/build.sh kernel [--clean|--reuse]
  bash sh/build.sh update
  bash sh/build.sh status
  bash sh/build.sh clean [--outputs]
  bash sh/build.sh rootfs [debian]
  bash sh/build.sh all [--clean|--reuse]

The builder clones the kernel branch msm89x7/latest from
https://gitlab.com/vanadium-oss/msm89x7/Mainline/linux.git into its cache.

The builder creates a Debian arm64 rootfs with:
  - USB Gadget networking (RNDIS / CDC-NCM with static IP 172.16.42.1)
  - Preconfigured OpenSSH server (root login enabled)
  - NetworkManager & WPA Supplicant for Wi-Fi
  - SimpleFB and DRM display drivers for early boot and desktop (Phosh/Sway)
  - Ext4 auto-growing rootfs partition service
  - Native kernel modules and WCN3620 Wi-Fi firmware
EOF
}

command="${1:-help}"
shift || true
case "$command" in
  kernel) exec bash "$ROOT/sh/mainline/build.sh" "$@" ;;
  update) exec bash "$ROOT/sh/mainline/update-source.sh" "$@" ;;
  status) exec bash "$ROOT/sh/status.sh" "$@" ;;
  clean) exec bash "$ROOT/sh/clean.sh" "$@" ;;
  rootfs) exec bash "$ROOT/sh/rootfs/build.sh" "$@" ;;
  all)
    case "${1:-}" in
      --clean) bash "$ROOT/sh/mainline/build.sh" --clean ;;
      --reuse) bash "$ROOT/sh/mainline/build.sh" --reuse ;;
      '') bash "$ROOT/sh/mainline/build.sh" ;;
      *) usage; exit 2 ;;
    esac
    exec bash "$ROOT/sh/rootfs/build.sh" debian
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
