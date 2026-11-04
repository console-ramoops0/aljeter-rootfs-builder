#!/usr/bin/env bash
# Aljeter Debian arm64 profile. Existing environment variables take precedence.

: "${ALJETER_DEBIAN_SUITE:=trixie}"
: "${ALJETER_DEBIAN_ARCH:=arm64}"
: "${ALJETER_DEBIAN_MIRROR:=http://deb.debian.org/debian}"
: "${ALJETER_DEBIAN_COMPONENTS:=main,contrib,non-free,non-free-firmware}"

# Essential runtime packages for Moto G6 Play (aljeter):
# Includes USB gadget network, SSH server, NetworkManager/WPA for Wi-Fi,
# Mesa/freedreno for Adreno 505 GPU, and disk/time utilities.
: "${ALJETER_DEBIAN_PACKAGES:=systemd-sysv udev dbus network-manager wpasupplicant iproute2 iputils-ping kmod e2fsprogs ca-certificates locales openssh-server systemd-timesyncd systemd-zram-generator wireless-regdb rfkill libegl-mesa0 libgl1-mesa-dri libgles2 sudo nano curl htop parted fbset}"

: "${ALJETER_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE:=0}"
: "${ALJETER_DEBIAN_IMAGE_SIZE_MIB:=1536}"
: "${ALJETER_DEBIAN_MIN_FREE_MIB:=128}"
: "${ALJETER_ROOTFS_LABEL:=debian-root}"
: "${ALJETER_ROOT_PASSWORD:=aljeter}"
: "${ALJETER_TIMEZONE:=America/Sao_Paulo}"

# NTP time servers (phone has no battery-backed RTC)
: "${ALJETER_NTP_SERVERS:=pool.ntp.org time.cloudflare.com time.google.com}"
: "${ALJETER_FALLBACK_NTP_SERVERS:=time.google.com time.cloudflare.com}"
: "${ALJETER_NTP_ROOT_DISTANCE_MAX_SEC:=20}"
