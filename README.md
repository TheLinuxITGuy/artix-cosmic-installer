# Artix Linux + COSMIC Installer

This script installs **Artix Linux** (Arch without systemd) on one whole disk. You get:

| | |
|---|---|
| **Kernel** | `linux-zen` and its headers |
| **Filesystem** | **XFS** root. On UEFI there's also a FAT32 EFI partition. No swap. |
| **Init** | **dinit** (recommended) or **OpenRC** |
| **Desktop** | **COSMIC**, with **cosmic-greeter** as the login screen (it runs on greetd) |
| **Apps** | DaVinci Resolve **Studio**, Audacity, Claude desktop, OBS Studio, Steam, Discord, **Brave Origin** (browser) |
| **Extras** | PipeWire audio, NetworkManager, Bluetooth, GPU drivers picked to match your hardware, the `yay` AUR helper |

> ⚠️ **The script erases the whole disk you pick.** Back up anything you need first. It won't start until you type `ERASE`.

---

## Contents

1. [Requirements](#1-requirements)
2. [Download the Artix ISO](#2-download-the-artix-iso)
3. [Write the ISO to a USB stick](#3-write-the-iso-to-a-usb-stick)
4. [Boot the USB stick](#4-boot-the-usb-stick)
5. [Connect to the internet](#5-connect-to-the-internet)
6. [Download and run the script](#6-download-and-run-the-script)
7. [Answer the prompts](#7-answer-the-prompts)
8. [Reboot into COSMIC](#8-reboot-into-cosmic)
9. [After the first boot](#9-after-the-first-boot)
10. [Troubleshooting](#10-troubleshooting)
11. [What the script does](#11-what-the-script-does)

---

## 1. Requirements

- A 64-bit (x86_64) PC. **UEFI is recommended.** Legacy BIOS works too.
- At least **8 GB of RAM**. 16 GB or more is better for DaVinci Resolve.
- A disk of **128 GB or more**. Steam games and Resolve take a lot of space.
- A **USB stick of 2 GB or more**.
- A **wired or Wi-Fi internet connection**. Everything is downloaded during the install.
- **Secure Boot turned off** in your firmware settings, because Artix's GRUB isn't signed.
- **NVIDIA users:** the script installs `nvidia-open-dkms`, which needs a **GTX 16xx / RTX 20-series or newer** card. For older cards, see [Troubleshooting](#nvidia-card-older-than-turing-gtx-10xx-and-earlier).
- **DaVinci Resolve Studio** needs a paid license key or a USB dongle. It also needs a GPU that supports OpenCL or CUDA.

---

## 2. Download the Artix ISO

1. Go to **https://artixlinux.org/download.php**.
2. Under **Official ISO images**, download the **base** image for the init you want:
   - **`artix-base-dinit-YYYYMMDD-x86_64.iso`** ← **recommended**. The COSMIC greeter setup in this script was modeled on a dinit setup that Artix users have tested.
   - `artix-base-openrc-YYYYMMDD-x86_64.iso` also works.

   Use a **base** ISO, not a desktop ISO. The script installs the desktop itself. The script also installs the same init as the ISO you boot, so pick the init you want now. (You can override this; see [Answer the prompts](#7-answer-the-prompts).)
3. **Check the download.** The download page lists a SHA256 checksum for every ISO. Compare it with your file:

   **Linux / macOS**
   ```bash
   sha256sum artix-base-dinit-*.iso        # macOS: shasum -a 256 artix-base-dinit-*.iso
   ```
   **Windows (PowerShell)**
   ```powershell
   Get-FileHash .\artix-base-dinit-*.iso -Algorithm SHA256
   ```
   The hash must match the one on the page exactly. If it doesn't, download the ISO again.

---

## 3. Write the ISO to a USB stick

Writing the ISO erases everything on the USB stick.

**Linux**
```bash
lsblk                                   # find the USB stick, e.g. /dev/sdb (NOT a partition like /dev/sdb1)
sudo dd if=artix-base-dinit-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Windows**
- **Rufus** (https://rufus.ie): pick the ISO and click Start. When Rufus asks, choose **"Write in DD Image mode"**.
- **balenaEtcher** (https://etcher.balena.io): Flash from file → choose the USB stick → Flash.

**Ventoy** also works. Copy the ISO onto the Ventoy stick. If the normal mode won't boot, choose *"Boot in grub2 mode"*.

---

## 4. Boot the USB stick

1. Plug in the USB stick and power on the PC. Press your **boot menu key** right away. Common keys are **F12**, F11, F10, F8 or Esc, and some PCs use F2 or Del for setup.
2. In the firmware setup:
   - **Turn off Secure Boot.**
   - Leave the boot mode on **UEFI**. Turn off CSM/Legacy unless you mean to install in BIOS mode.
3. Choose the **UEFI: <your USB stick>** entry.
4. At the Artix boot menu, choose the first entry. It's named like **"From CD/DVD/ISO: artix.x86_64"**.
5. Log in to the live system:
   ```
   login:    root
   password: artix
   ```
   (You can also log in as `artix` / `artix` and then run `su` to become root. The password is `artix`.)

**Optional:** to confirm you booted in UEFI mode, run `ls /sys/firmware/efi`. If it lists files, you're in UEFI mode.

---

## 5. Connect to the internet

**Wired Ethernet** connects automatically.

**USB tethering from your phone** also works without any setup. Plug the phone in, turn on USB tethering, and it shows up as a wired connection. If it doesn't connect by itself, run `dhcpcd`.

**Wi-Fi.** Current Artix ISOs use **NetworkManager (`nmcli`)**. ConnMan's `connmanctl` is no longer included.
```bash
rfkill unblock wifi
nmcli radio wifi on
nmcli device wifi list                              # find your network name (SSID)
nmcli --ask device wifi connect "YourNetworkName"   # asks for the Wi-Fi password
```
Type the network name exactly as the list shows it. Keep the quotes if it has spaces.

<details>
<summary>Older or different ISOs (no <code>nmcli</code>)</summary>

Check which Wi-Fi tool the ISO has, and find your interface name:
```bash
command -v nmcli iwctl wpa_supplicant connmanctl
ip link                                            # e.g. wlan0 or wlp1s0
```
In the commands below, replace `wlan0` with your interface name.

**`iwctl` (iwd)**
```bash
iwctl station wlan0 scan
iwctl station wlan0 get-networks
iwctl station wlan0 connect "YourNetworkName"
dhcpcd wlan0                                       # only if you don't get an IP address
```

**`wpa_supplicant` only**
```bash
wpa_passphrase "YourNetworkName" 'YourPassword' > /tmp/wifi.conf
wpa_supplicant -B -i wlan0 -c /tmp/wifi.conf
dhcpcd wlan0
```

**`connmanctl` (ConnMan)**
```
connmanctl
agent on
enable wifi
scan wifi
services
connect wifi_abc123_managed_psk
quit
```
</details>

**Check that you're online:**
```bash
ping -c 3 artixlinux.org
```

---

## 6. Download and run the script

```bash
curl -LO https://raw.githubusercontent.com/TheLinuxITGuy/artix-cosmic-installer/main/artix-cosmic-install.sh
less artix-cosmic-install.sh            # optional: read it first (press q to quit)
bash artix-cosmic-install.sh
```

> Don't run it as `curl … | bash`. The script asks you questions, so it has to run from a file.

---

## 7. Answer the prompts

The script asks for the following. Press **Enter** to accept the default shown in `[brackets]`.

| Prompt | Default | Notes |
|---|---|---|
| Target disk | — | Pick your **internal** drive from the list, e.g. `/dev/nvme0n1`. Your USB stick appears in the list too, so check the size and model to avoid choosing it. **This disk will be wiped.** |
| Init system | init of the ISO you booted | `dinit` or `openrc` |
| Hostname | `artix` | |
| Username | — | Your login. It's added to `wheel`, so you can use sudo. |
| Timezone | `America/Denver` | Any `Region/City` from `/usr/share/zoneinfo`, e.g. `America/New_York` |
| Locale | `en_US.UTF-8` | |
| Console keymap | `us` | |
| Install DaVinci Resolve Studio | `y` | Downloads about 3 GB from Blackmagic and builds the package. You can answer `n` and install it later. |
| Password | — | Your user's password, typed twice. There's no separate root password: root gets the same one, and your user has full admin rights through `sudo`. Only a hashed copy is stored during the install, and it's deleted afterwards. |

After that you'll see a summary. Type **`ERASE`** to start.

The install takes roughly **20 to 60 minutes**, depending on your internet speed and on DaVinci Resolve.

### Skipping the prompts (advanced)

You can set any answer ahead of time with an environment variable:

```bash
DISK=/dev/nvme0n1 INIT=dinit NEW_HOSTNAME=studio NEW_USER=chris \
TIMEZONE=America/Denver INSTALL_RESOLVE=y \
bash artix-cosmic-install.sh
```

| Variable | Meaning |
|---|---|
| `DISK` `INIT` `NEW_HOSTNAME` `NEW_USER` `TIMEZONE` `LOCALE` `KEYMAP` `INSTALL_RESOLVE` | Same as the prompts above |
| `GPU` | Overrides the GPU detection with any of `amd` `intel` `nvidia` `vm`, separated by spaces (e.g. `GPU="intel nvidia"` for a hybrid laptop) |
| `RESOLVE_PKG` | `davinci-resolve-studio` by default. Set it to `davinci-resolve` for the free edition. |
| `EXTRA_PKGS` | Extra packages from the Artix/Arch repos, separated by spaces. Empty by default. |
| `AUR_EXTRA_PKGS` | Extra AUR packages, separated by spaces. The default is `brave-origin-bin` (Brave Origin). `AUR_EXTRA_PKGS=""` skips it. |
| `LOCK_ROOT=1` | Locks the root account instead of giving it your password, Ubuntu-style. Use `sudo` for everything. |
| `FORCE=1` | Lets the script run on something other than the Artix ISO (not recommended) |

The password is always asked for interactively.

---

## 8. Reboot into COSMIC

When the script prints **Done!**, run:

```bash
umount -R /mnt
reboot
```

Remove the USB stick when the screen goes dark. GRUB boots `linux-zen`, and the **COSMIC login screen (cosmic-greeter)** appears. Sign in with the username and password you chose.

If anything optional failed during the install (for example, an AUR build), the script lists it at the end. Install those items after the first boot; see [Troubleshooting](#10-troubleshooting).

---

## 9. After the first boot

- **Update everything:** `sudo pacman -Syu`. For AUR packages too, run `yay -Syu`.
- **Wi-Fi:** use the network applet in the COSMIC panel, or run `nmtui` in a terminal.
- **Steam:** sign in, then go to *Settings → Compatibility → Enable Steam Play for all other titles* to run Windows games through Proton.
- **DaVinci Resolve Studio:** start it from the app library. On first launch, enter your license key or plug in your dongle.
  - AMD GPUs use `rocm-opencl-runtime`, Intel GPUs use `intel-compute-runtime`, and NVIDIA GPUs use `opencl-nvidia`. The script installs the one that matches your GPU.
  - If activation says *"Cannot activate license"*, make sure your user can write to `/opt/resolve/.license`. The script sets that up, but a reinstall can reset it: `sudo chown -R $USER /opt/resolve/.license`.
  - On Linux, Resolve can't import or export H.264/H.265 or AAC in the free edition. **Studio** supports H.264/H.265 with GPU acceleration. For AAC audio, use PCM/WAV or transcode with ffmpeg.
- **Brave Origin:** your browser. It's Brave without the AI, Rewards, Wallet and VPN features, but Shields (ad and tracker blocking) is still there. It's free on Linux: during setup, choose the free option instead of buying a license.
- **Claude desktop:** open **Claude** from the app library and sign in. It comes from the AUR package `claude-desktop`, which repackages Anthropic's official Linux `.deb`. The Linux app is in beta. Cowork's VM needs KVM, so your user is added to the `kvm` group.
- **OBS Studio:** to capture the screen, add a **Screen Capture (PipeWire)** source. COSMIC's portal asks which screen or window to share.
- **Discord:** screen sharing on Wayland also goes through the portal.

---

## 10. Troubleshooting

### You get a text login prompt instead of the COSMIC greeter
The greeter runs on **VT7**. Press **Ctrl+Alt+F7**. Or log in on tty1 and check the services:

```bash
# dinit
sudo dinitctl status cosmic-greeter
sudo dinitctl status cosmic-greeter-daemon
sudo dinitctl start  cosmic-greeter

# OpenRC
sudo rc-service cosmic-greeter status
sudo rc-service cosmic-greeter restart
```
To start COSMIC without the greeter, log in on a TTY and run `start-cosmic`.

The files the script writes for the greeter are:
- `/etc/greetd/config.toml`. It runs `cosmic-greeter-start` as the `cosmic-greeter` user on VT7. The original file is saved as `config.toml.orig`.
- dinit: `/etc/dinit.d/cosmic-greeter`, `cosmic-greeter-daemon`, `cosmic-greeter-pre`
- OpenRC: `/etc/init.d/cosmic-greeter`, `/etc/init.d/cosmic-greeter-daemon`

### No sound
Artix has no `systemd --user`, so PipeWire is started by an autostart entry: `/etc/xdg/autostart/artix-pipewire.desktop`, which runs `/usr/local/bin/artix-pipewire-start`. Check whether it's running:
```bash
pgrep -a pipewire; pgrep -a wireplumber
```
If they aren't running, start them with `artix-pipewire-start &`, then log out and back in.

### An AUR package failed (Claude desktop / Brave Origin / DaVinci Resolve)
AUR builds sometimes break because of upstream changes. Retry after the first boot:
```bash
yay -S claude-desktop
yay -S brave-origin-bin
yay -S davinci-resolve-studio      # or davinci-resolve for the free edition
```
If `claude-desktop` keeps failing, try `claude-desktop-appimage`. If Resolve's download from Blackmagic fails, download the Linux zip from https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion. Put it in `~/.cache/yay/davinci-resolve-studio/` and run `yay -S davinci-resolve-studio` again.

### NVIDIA card older than Turing (GTX 10xx and earlier)
Replace the open driver with the legacy branch from the AUR. Check the Arch wiki NVIDIA page for the right package for your card, for example:
```bash
sudo pacman -Rns nvidia-open-dkms
yay -S nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils
```

### The PC boots straight to the firmware, or there's no "Artix" boot entry
The script also installs GRUB to the fallback path `EFI/BOOT/BOOTX64.EFI`, so most firmware finds it anyway. If yours doesn't, pick the disk itself in the boot menu or add an entry with `efibootmgr`.

### Where's the install log?
On the installed system: `/var/log/artix-cosmic-install.log`.

---

## 11. What the script does

**Stage 1** runs on the live ISO:
1. It checks that you're root on the Artix ISO, that you're online, and whether you booted in UEFI or BIOS mode. It also installs any missing tools: xfsprogs, dosfstools, pciutils, openssl.
2. It detects your CPU microcode (Intel or AMD) and your GPU vendors.
3. It asks the [prompts](#7-answer-the-prompts) and waits for you to type `ERASE`.
4. It partitions the disk with GPT using `sfdisk`:
   - UEFI: `1 GiB EFI (FAT32)` + `XFS /`
   - BIOS: `1 MiB bios_grub` + `XFS /`

   No swap is created.
5. It runs `basestrap` with `base base-devel <init> elogind-<init> dbus-<init> linux-zen linux-zen-headers linux-firmware xfsprogs grub networkmanager-<init> sudo git …`. Then it writes the fstab with `fstabgen -U`.

**Stage 2** runs inside `artix-chroot`:
1. It sets the timezone, locale, keymap, hostname and `/etc/hosts`.
2. It sets up pacman. It turns on Artix `[lib32]`, installs `artix-archlinux-support`, and adds the Arch `[extra]` and `[multilib]` repos *after* the Artix repos. COSMIC, Steam and Discord come from those repos.
3. It creates your user (`wheel`, `audio`, `video`, `input`, `kvm`, …) and lets `wheel` use sudo. Root gets the same password as your user, or is locked with `LOCK_ROOT=1`.
4. It installs GPU drivers: Mesa and Vulkan for AMD and Intel, plus `nvidia-open-dkms` for NVIDIA. It installs the 32-bit libraries too, for Steam.
5. It installs COSMIC: the `cosmic` group, greetd, PipeWire, fonts, Bluetooth and gnome-keyring.
6. It sets up cosmic-greeter without systemd. It creates the `cosmic-greeter` user, a greetd config on VT7 and the PAM files. Then it writes dinit or OpenRC services for `cosmic-greeter-daemon` and greetd. Arch's packages ship only systemd units, so the script writes these by hand.
7. It adds the PipeWire autostart.
8. It installs Audacity, OBS Studio, Steam and Discord.
9. It enables these services: dbus, elogind, NetworkManager, bluetooth, cosmic-greeter-daemon and cosmic-greeter.
10. It builds `yay` and uses it to install `claude-desktop`, `brave-origin-bin` and `davinci-resolve-studio`, along with the OpenCL runtime that matches your GPU. It gives the user temporary sudo rights for these builds and removes them afterwards.
11. It runs `mkinitcpio -P` and `grub-install` (plus the fallback copy on UEFI), then `grub-mkconfig`.

---

### Notes and disclaimer
- COSMIC is developed for systemd distributions. On Artix it's a community setup, so a COSMIC update could need small fixes to the greeter or session.
- DaVinci Resolve, Steam, Discord and Claude desktop are proprietary software under their own licenses. This script only installs them through Artix/Arch repositories and the AUR.
- Use this script at your own risk, and test it in a VM first if you can. Make sure the VM uses UEFI firmware.

MIT License
