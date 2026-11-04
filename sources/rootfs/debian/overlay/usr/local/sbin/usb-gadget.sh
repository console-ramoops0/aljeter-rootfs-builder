#!/bin/sh
set -e

G=/sys/kernel/config/usb_gadget/aljeter
mount -t configfs none /sys/kernel/config 2>/dev/null || true
mkdir -p "$G/strings/0x409" "$G/functions/rndis.usb0" \
  "$G/functions/rndis.usb0/os_desc/interface.rndis" \
  "$G/configs/c.1/strings/0x409" "$G/os_desc"

# Motorola RNDIS identity (compatible with Linux, macOS, and Windows)
echo 0x22b8 > "$G/idVendor"
echo 0x7102 > "$G/idProduct"
echo 0xef > "$G/bDeviceClass"
echo 0x04 > "$G/bDeviceSubClass"
echo 0x01 > "$G/bDeviceProtocol"
echo Motorola > "$G/strings/0x409/manufacturer"
echo "Moto G6 Play (aljeter)" > "$G/strings/0x409/product"
echo 42:61:6c:6a:65:74 > "$G/functions/rndis.usb0/host_addr"
echo 42:61:6c:6a:65:75 > "$G/functions/rndis.usb0/dev_addr"
echo rndis > "$G/configs/c.1/strings/0x409/configuration"

# Publish Microsoft OS descriptor so Windows binds its RNDIS driver automatically
echo 1 > "$G/os_desc/use"
echo 0xcd > "$G/os_desc/b_vendor_code"
echo MSFT100 > "$G/os_desc/qw_sign"
echo RNDIS > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"
ln -sfn "$G/functions/rndis.usb0" "$G/configs/c.1/"
ln -sfn "$G/configs/c.1" "$G/os_desc/"

for i in $(seq 1 30); do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "${UDC:-}" ] || { echo "no-udc" >&2; exit 1; }
echo "$UDC" > "$G/UDC"

# Wait for interface to appear and detect its name
IFACE="usb0"
for i in $(seq 1 10); do
    if [ -d "/sys/class/net/usb0" ]; then
        IFACE="usb0"
        break
    fi
    DETECTED="$(ls /sys/class/net/ 2>/dev/null | grep -E '^(usb|rndis|enx)' | head -n 1 || true)"
    if [ -n "$DETECTED" ]; then
        IFACE="$DETECTED"
        break
    fi
    sleep 0.5
done

ip addr flush dev "$IFACE" 2>/dev/null || true
ip addr add 172.16.42.1/24 dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true

# Start DHCP server for host computer if dnsmasq is available
if command -v dnsmasq >/dev/null 2>&1; then
    killall dnsmasq 2>/dev/null || true
    dnsmasq --interface="$IFACE" \
      --bind-interfaces \
      --dhcp-range=172.16.42.2,172.16.42.10,255.255.255.0,1h \
      --listen-address=172.16.42.1 \
      --port=0 \
      --leasefile-ro 2>/dev/null || true
fi
