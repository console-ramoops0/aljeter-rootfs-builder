# Aljeter Debian ARM64 & Mainline Linux Builder
### Motorola Moto G6 Play (MSM8937 / MSM8920)

Reprodutível, automatizado e pronto para boot com **Debian GNU/Linux (Trixie/Bookworm)** no **Moto G6 Play (`aljeter` / `jeter`)** usando o kernel **Linux Mainline** e o bootloader **lk2nd**.

---

## 🚀 Recursos Habilitados

- **Bootloader lk2nd:** Imagem [`lk2nd-aljeter.img`](sources/lk2nd-aljeter.img) inclusa, pronta para DTB matching e chaveamento de painel.
- **Saída de Vídeo (Display):**
  - `simple-framebuffer` ativo em `720x1440` (logs no display desde o segundo zero).
  - Driver DRM nativo KMS (`msm`) com suporte a todos os painéis Tianma, DJN e Wistron.
  - Aceleração gráfica via Mesa / freedreno (Adreno 505).
- **USB & SSH Out-of-the-Box:**
  - ConfigFS USB Gadget via RNDIS / CDC-NCM.
  - Endereço IP estático no celular: `172.16.42.1/24`.
  - Servidor OpenSSH pré-configurado com login root permitido (`PermitRootLogin yes`).
  - Host keys geradas automaticamente no primeiro boot.
- **Rede Wi-Fi & Bluetooth:**
  - Driver `wcn36xx` e módulo WCNSS.
  - NetworkManager e WPA Supplicant ativos para conexão via `nmcli` ou `nmtui`.
- **Armazenamento:**
  - Partição ext4 autoexpansível (`aljeter-grow-rootfs`) que redimensiona para ocupar todo o eMMC ou MicroSD no primeiro boot.

---

## 🛠️ Como Compilar

### 1. Dependências do Host
Em uma distribuição baseada em Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  git ca-certificates curl make bc bison flex \
  gcc-aarch64-linux-gnu device-tree-compiler libfdt-dev libssl-dev libelf-dev \
  python3 rsync cpio gzip xz-utils zstd \
  e2fsprogs qemu-user-static binfmt-support mmdebstrap \
  openssh-client openssl kmod file dosfstools
sudo update-binfmts --enable qemu-aarch64
```

### 2. Comandos de Compilação

- **Compilar tudo (Kernel + Boot.img + RootFS Debian):**
  ```bash
  bash sh/build.sh all
  ```

- **Apenas o Kernel Mainline & Boot Image:**
  ```bash
  bash sh/build.sh kernel
  ```

- **Apenas o RootFS Debian ARM64:**
  ```bash
  bash sh/build.sh rootfs debian
  ```

Os arquivos gerados são gravados em:
- Kernel e imagens de boot: `build/mainline/releases/`
- Imagens ext4 e tarball Debian: `build/rootfs/debian/releases/`

---

## 📱 Como Dar Boot e Testar no Aparelho

### Passo 1: Entrar no lk2nd
Coloque o Moto G6 Play no modo Fastboot do fabricante (botão Power + Vol-) e carregue o `lk2nd`:
```bash
fastboot boot sources/lk2nd-aljeter.img
```
*(O display vai acender com o menu do lk2nd e o logo do Tux).*

Se quiser gravar o `lk2nd` permanentemente na partição de boot original:
```bash
fastboot flash boot sources/lk2nd-aljeter.img
```

### Passo 2: Gravar o Kernel Mainline e a RootFS Debian
Já dentro da interface fastboot do **lk2nd**:

1. **Gravar o boot.img do Linux:**
   ```bash
   fastboot flash boot build/mainline/releases/kernel-*/boot.img
   ```

2. **Gravar a partição de sistema (userdata ou MicroSD):**
   - *Via fastboot na memória interna (userdata):*
     ```bash
     fastboot flash userdata build/rootfs/debian/releases/debian-*/debian-*.ext4
     ```
   - *Ou gravando num cartão MicroSD via PC:*
     ```bash
     sudo dd if=build/rootfs/debian/releases/debian-*/debian-*.ext4 of=/dev/sdX bs=4M status=progress conv=fsync
     ```

### Passo 3: Reiniciar e Conectar via SSH
Reinicie o aparelho. A tela exibirá os logs do Linux (*fbcon*) e carregará o Debian.

1. Conecte o cabo USB no computador.
2. O computador reconhecerá a placa de rede USB (`usb0` / `enp...`).
3. Conecte diretamente via SSH:
   ```bash
   ssh root@172.16.42.1
   ```
4. **Senha padrão:** `aljeter`

---

## 📶 Como Conectar no Wi-Fi pelo Terminal

Com a sessão SSH aberta no celular:
```bash
nmcli dev wifi list
nmcli dev wifi connect "NomeDaSuaRede" password "SuaSenhaAqui"
```

---

## 🖥️ Como Iniciar a Interface Gráfica (Phosh / Wayland)

Se desejar instalar a interface móvel do GNOME:
```bash
sudo apt update
sudo apt install -y phosh phoc squeekboard
systemctl enable phosh
systemctl start phosh
```
