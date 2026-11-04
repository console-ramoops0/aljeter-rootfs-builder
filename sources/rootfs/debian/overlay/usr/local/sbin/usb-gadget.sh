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
[ -n "${UDC:-}" ] || { echo no-udc >&2; exit 1; }
echo "$UDC" > "$G/UDC"
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
ip link set usb0 up 2>/dev/null || true
