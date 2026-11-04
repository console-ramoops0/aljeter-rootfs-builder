# Rootfs Debian do Aljeter (Moto G6 Play - MSM8937)

## Fluxo de Criação

1. `profile.sh` define os padrões do Debian 13 (Trixie) arm64.
2. `build.sh` cria o sistema mínimo com `mmdebstrap` e suporte a QEMU aarch64.
3. O checkpoint do kernel Mainline e os módulos compilados são incorporados.
4. Os firmwares WCNSS/Pronto (Wi-Fi/Bluetooth) e microcódigo da GPU Adreno 505/530 são instalados.
5. O rootfs inclui o runtime Mesa/Freedreno para aceleração gráfica OpenGL ES no Adreno 505.
6. O overlay instala USB Gadget RNDIS com DHCP automático (`172.16.42.1`), servidor SSH root, gerenciamento de Wi-Fi via NetworkManager e auto-expansão ext4.
7. O script remove pacotes desnecessários e caches, ajusta permissões e gera a imagem ext4 (`.ext4`) e o tarball compactado (`.tar.zst`).

## Personalização

Os parâmetros podem ser customizados via variáveis de ambiente:

```bash
ALJETER_DEBIAN_IMAGE_SIZE_MIB=1536 \
ALJETER_ROOT_PASSWORD=aljeter \
ALJETER_TIMEZONE="America/Sao_Paulo" \
ALJETER_BOOT_ROOT="PARTLABEL=userdata" \
bash sh/build.sh rootfs debian
```

O rootfs é Debian arm64 puro. O kernel monta a partição `userdata` pelo `PARTLABEL=userdata`, funcionando perfeitamente tanto no eMMC interno quanto em cartões MicroSD (ajustando `ALJETER_BOOT_ROOT=/dev/mmcblk1p1`).

## Conexão & Primeiro Boot

1. **USB Gadget & SSH:** Ao plugar o celular no PC via USB, o aparelho atribui `172.16.42.1` a si mesmo e entrega `172.16.42.2` via DHCP ao computador host.
   - Conexão: `ssh root@172.16.42.1` (Senha: `aljeter`)
2. **Wi-Fi:** Gerenciado pelo NetworkManager:
   - `nmcli dev wifi list`
   - `nmcli dev wifi connect "NomeDaRede" password "Senha"`
3. **Display:** O console Linux (`fbcon`) aparece diretamente no display do celular a 720x1440 via simple-framebuffer desde o segundo zero.
