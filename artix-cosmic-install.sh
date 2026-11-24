#!/usr/bin/env bash
# =============================================================================
#  Artix Linux + COSMIC installer
#  linux-zen kernel | XFS root | COSMIC desktop + cosmic-greeter
#  Apps: DaVinci Resolve Studio, Audacity, Claude desktop, OBS Studio,
#        Steam, Discord, Brave Origin
#
#  Run from an Artix *base* live ISO (dinit or OpenRC) as root:
#      bash artix-cosmic-install.sh
#
#  THIS SCRIPT ERASES THE WHOLE TARGET DISK.
#
#  Every prompt can be pre-answered with an environment variable, e.g.:
#      DISK=/dev/nvme0n1 NEW_USER=chris NEW_HOSTNAME=artix bash artix-cosmic-install.sh
#  See README.md for the full list.
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
TARGET=/mnt
CONF_IN_TARGET=/root/artix-cosmic-install.conf
SCRIPT_IN_TARGET=/root/artix-cosmic-install.sh
LOG=/tmp/artix-cosmic-install.log

# ---------------------------------------------------------------- helpers ---
if [[ -t 1 ]]; then
    C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_OFF=$'\e[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
info() { printf '%s  ->%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s  !! %s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
trap 'die "Command failed on line $LINENO: $BASH_COMMAND (log: $LOG)"' ERR

# ask VAR "Question" "default" -- keeps an existing (env) value if already set
ask() {
    local __var=$1 __q=$2 __def=${3:-} __ans
    if [[ -n "${!__var:-}" ]]; then info "$__q: ${!__var} (preset)"; return; fi
    read -rp "  $__q${__def:+ [$__def]}: " __ans
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_password VAR "label" -- stores a SHA-512 crypt hash, never the plain text
ask_password() {
    local __var=$1 __label=$2 __p1 __p2
    while true; do
        read -rsp "  Password for $__label: " __p1; echo
        read -rsp "  Repeat password for $__label: " __p2; echo
        [[ -n "$__p1" ]] || { warn "Password can't be empty."; continue; }
        [[ "$__p1" == "$__p2" ]] || { warn "Passwords don't match."; continue; }
        break
    done
    printf -v "$__var" '%s' "$(printf '%s' "$__p1" | openssl passwd -6 -stdin)"
}

part_path() {  # part_path /dev/nvme0n1 2 -> /dev/nvme0n1p2
    if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi
}

# =============================================================================
#  STAGE 1 -- runs on the live ISO
# =============================================================================
preflight() {
    step "Pre-flight checks (installer v$SCRIPT_VERSION)"
    [[ $EUID -eq 0 ]] || die "Run as root (on the live ISO: 'su', password 'artix')."
    grep -qi '^ID=artix' /etc/os-release 2>/dev/null \
        || [[ "${FORCE:-0}" == 1 ]] \
        || die "This doesn't look like the Artix live ISO. Set FORCE=1 to override."
    [[ -t 0 ]] || die "Run the script from a file (bash artix-cosmic-install.sh), not piped into bash -- it needs your keyboard for prompts."

    if [[ -d /sys/firmware/efi/efivars ]]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi
    info "Boot mode: $BOOT_MODE"

    ping -c1 -W5 artixlinux.org &>/dev/null || die "No internet. Connect first (see README: 'Connect to the internet')."
    info "Internet: OK"

    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
    local need=()
    command -v mkfs.xfs  &>/dev/null || need+=(xfsprogs)
    command -v mkfs.fat  &>/dev/null || need+=(dosfstools)
    command -v lspci     &>/dev/null || need+=(pciutils)
    command -v openssl   &>/dev/null || need+=(openssl)
    if ((${#need[@]})); then
        info "Installing missing live-ISO tools: ${need[*]}"
        pacman -Sy --noconfirm --needed "${need[@]}"
    fi
    for c in basestrap fstabgen artix-chroot sfdisk wipefs lsblk; do
        command -v "$c" &>/dev/null || die "Missing '$c' -- are you on the Artix live ISO?"
    done
}

detect_hardware() {
    step "Detecting hardware"
    case "$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')" in
        GenuineIntel) UCODE=intel-ucode ;;
        AuthenticAMD) UCODE=amd-ucode ;;
        *)            UCODE="" ;;
    esac
    info "CPU microcode: ${UCODE:-none}"

    if [[ -z "${GPU:-}" ]]; then
        local gpus; gpus=$(lspci -nn | grep -Ei 'vga|3d|display' || true)
        GPU=""
        grep -qi  'NVIDIA'                                   <<<"$gpus" && GPU+="nvidia "
        grep -Eq  'AMD/ATI|Advanced Micro Devices|Radeon'    <<<"$gpus" && GPU+="amd "
        grep -q   'Intel Corporation'                        <<<"$gpus" && GPU+="intel "
        grep -Eqi 'VMware|Virtio|QXL|Bochs|VirtualBox|Red Hat' <<<"$gpus" && GPU+="vm "
        GPU=${GPU% }
        [[ -n "$GPU" ]] || GPU=vm
    fi
    info "GPU driver set(s): $GPU   (override with GPU=\"amd|intel|nvidia|vm\")"
}

gather_config() {
    step "Installation settings"
    echo "  Available disks:"
    lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$NF=="disk"{print "    "$0}'
    echo
    ask DISK "Target disk (WILL BE ERASED)" ""
    [[ -b "$DISK" ]] || die "'$DISK' is not a block device."
    [[ "$(lsblk -dno TYPE "$DISK")" == disk ]] || die "'$DISK' is not a whole disk."

    local disk_gib=$(( $(lsblk -bdno SIZE "$DISK") / 1024 / 1024 / 1024 ))
    (( disk_gib >= 64 )) || warn "Disk is ${disk_gib} GiB. 128 GiB+ is recommended (Steam + DaVinci Resolve are big)."

    local default_init=dinit
    if command -v openrc &>/dev/null && [[ -d /run/openrc ]]; then default_init=openrc; fi
    ask INIT "Init system (dinit/openrc)" "$default_init"
    [[ "$INIT" == dinit || "$INIT" == openrc ]] || die "INIT must be 'dinit' or 'openrc'."

    ask NEW_HOSTNAME "Hostname" "artix"
    [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Invalid hostname."
    ask NEW_USER "Username" ""
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username (lowercase letters, digits, - and _)."
    ask TIMEZONE "Timezone (Region/City)" "America/Denver"
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone '$TIMEZONE'."
    ask LOCALE "Locale" "en_US.UTF-8"
    ask KEYMAP "Console keymap" "us"
    ask INSTALL_RESOLVE "Install DaVinci Resolve Studio from the AUR (large download, long build) y/n" "y"
    RESOLVE_PKG=${RESOLVE_PKG:-davinci-resolve-studio}
    EXTRA_PKGS=${EXTRA_PKGS-}
    AUR_EXTRA_PKGS=${AUR_EXTRA_PKGS-brave-origin-bin}

    echo
    ask_password USER_HASH "$NEW_USER"
    ask_password ROOT_HASH "root"

    local esp_line="n/a (BIOS: 1 MiB bios_grub partition)"
    [[ "$BOOT_MODE" == uefi ]] && esp_line="1 GiB FAT32 ESP -> /boot/efi"

    step "Summary"
    cat <<EOF
  Disk          : $DISK  (${disk_gib} GiB)  -- EVERYTHING ON IT WILL BE DELETED
  Layout        : $esp_line
                  rest = XFS root (/)   (no swap)
  Boot          : $BOOT_MODE + GRUB
  Init          : $INIT
  Kernel        : linux-zen (+ headers)
  Desktop       : COSMIC + cosmic-greeter (greetd)
  GPU drivers   : $GPU
  Apps          : Audacity, OBS Studio, Steam, Discord${EXTRA_PKGS:+, $EXTRA_PKGS}
  AUR           : claude-desktop${AUR_EXTRA_PKGS:+, $AUR_EXTRA_PKGS}$([[ "${INSTALL_RESOLVE,,}" == y* ]] && echo ", $RESOLVE_PKG")
  Host / user   : $NEW_HOSTNAME / $NEW_USER (sudo via wheel)
  Locale / TZ   : $LOCALE / $TIMEZONE / keymap $KEYMAP
EOF
    echo
    local confirm
    read -rp "  Type ERASE to wipe $DISK and install: " confirm
    [[ "$confirm" == ERASE ]] || die "Aborted -- nothing was changed."
}

partition_disk() {
    step "Partitioning $DISK"
    swapoff -a 2>/dev/null || true   # release any old swap on the target disk
    umount -R "$TARGET" 2>/dev/null || true
    wipefs -af "$DISK"

    local n=1 layout="label: gpt"$'\n'
    if [[ "$BOOT_MODE" == uefi ]]; then
        layout+="size=1GiB, type=U, name=EFI"$'\n'
        ESP_PART=$(part_path "$DISK" $n); n=$((n+1))
    else
        layout+="size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name=BIOSBOOT"$'\n'
        ESP_PART=""; n=$((n+1))
    fi
    layout+="type=L, name=ARTIX"$'\n'
    ROOT_PART=$(part_path "$DISK" $n)

    printf '%s' "$layout" | sfdisk --wipe always --wipe-partitions always "$DISK"
    partx -u "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 3

    step "Formatting (XFS root)"
    [[ -n "$ESP_PART" ]]  && mkfs.fat -F32 -n EFI "$ESP_PART"
    mkfs.xfs -f -L ARTIX "$ROOT_PART"

    mount "$ROOT_PART" "$TARGET"
    if [[ -n "$ESP_PART" ]]; then
        mkdir -p "$TARGET/boot/efi"
        mount "$ESP_PART" "$TARGET/boot/efi"
    fi
    lsblk "$DISK"
}

install_base() {
    step "Refreshing Artix keyring on the live ISO"
    pacman -Sy --noconfirm --needed artix-keyring

    step "Installing base system with basestrap ($INIT, linux-zen)"
    local pkgs=(
        base base-devel "$INIT" "elogind-$INIT" "dbus-$INIT"
        linux-zen linux-zen-headers linux-firmware mkinitcpio
        xfsprogs dosfstools grub os-prober
        networkmanager "networkmanager-$INIT"
        sudo git nano vim bash-completion man-db pciutils usbutils openssl
    )
    [[ "$BOOT_MODE" == uefi ]] && pkgs+=(efibootmgr)
    [[ -n "$UCODE" ]] && pkgs+=("$UCODE")
    basestrap "$TARGET" "${pkgs[@]}"

    step "Generating fstab"
    fstabgen -U "$TARGET" >> "$TARGET/etc/fstab"
    cat "$TARGET/etc/fstab"
}

run_stage2() {
    step "Handing over to the chroot (stage 2)"
    ( umask 077
      declare -p SCRIPT_VERSION DISK BOOT_MODE INIT NEW_HOSTNAME NEW_USER TIMEZONE LOCALE KEYMAP \
                 GPU UCODE INSTALL_RESOLVE RESOLVE_PKG EXTRA_PKGS AUR_EXTRA_PKGS USER_HASH ROOT_HASH \
                 > "$TARGET$CONF_IN_TARGET" )
    install -m700 "$(readlink -f "${BASH_SOURCE[0]}")" "$TARGET$SCRIPT_IN_TARGET"
    artix-chroot "$TARGET" /bin/bash "$SCRIPT_IN_TARGET" --stage2
    rm -f "$TARGET$CONF_IN_TARGET" "$TARGET$SCRIPT_IN_TARGET"
}

stage1() {
    preflight
    detect_hardware
    gather_config
    # Everything after the prompts is logged (passwords are never logged).
    exec > >(tee -a "$LOG") 2>&1
    partition_disk
    install_base
    run_stage2
    mkdir -p "$TARGET/var/log"
    cp "$LOG" "$TARGET/var/log/artix-cosmic-install.log" 2>/dev/null || true

    step "Done!"
    if [[ -s "$TARGET/root/artix-cosmic-install.failed" ]]; then
        warn "Some optional pieces failed and were skipped:"
        sed 's/^/      /' "$TARGET/root/artix-cosmic-install.failed" >&2
        warn "See README 'Troubleshooting' -- you can install them after first boot."
    fi
    cat <<EOF

  Artix + COSMIC is installed. Next:
      umount -R $TARGET
      reboot
  Remove the USB stick when the screen goes dark. You'll land on the
  COSMIC login screen -- sign in as '$NEW_USER'.
  Full log: /var/log/artix-cosmic-install.log (on the new system)
EOF
}

# =============================================================================
#  STAGE 2 -- runs inside artix-chroot
# =============================================================================
FAILED_FILE=/root/artix-cosmic-install.failed
record_failure() { echo "$*" >> "$FAILED_FILE"; warn "Skipped: $*"; }

pac() { pacman -S --noconfirm --needed "$@"; }

# Install a list; if the batch fails, retry one-by-one and record what failed.
pac_soft() {
    pac "$@" && return 0
    warn "Batch install failed -- retrying packages one at a time."
    local p
    for p in "$@"; do pac "$p" || record_failure "pacman: $p"; done
}

pkg_exists() { pacman -Si "$1" &>/dev/null; }

enable_service() {  # enable_service "name|altname" [openrc-runlevel]
    local names=$1 level=${2:-default} n
    local -a cand
    IFS='|' read -ra cand <<<"$names"
    for n in "${cand[@]}"; do
        if [[ "$INIT" == dinit && -f "/etc/dinit.d/$n" ]]; then
            ln -sf "/etc/dinit.d/$n" "/etc/dinit.d/boot.d/$n"; info "enabled (dinit): $n"; return 0
        elif [[ "$INIT" == openrc && -x "/etc/init.d/$n" ]]; then
            rc-update add "$n" "$level" >/dev/null; info "enabled (openrc/$level): $n"; return 0
        fi
    done
    record_failure "service not found: $names"
}

configure_system() {
    step "Timezone, locale, hostname"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc || true

    local esc=${LOCALE//./\\.}
    if grep -q "^#\s*$esc " /etc/locale.gen; then
        sed -i "s/^#\s*\($esc \)/\1/" /etc/locale.gen
    else
        echo "$LOCALE UTF-8" >> /etc/locale.gen
    fi
    grep -q '^en_US.UTF-8' /etc/locale.gen || sed -i 's/^#\s*\(en_US\.UTF-8 \)/\1/' /etc/locale.gen
    locale-gen
    echo "LANG=$LOCALE" > /etc/locale.conf

    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    [[ "$INIT" == openrc ]] && sed -i "s/^keymap=.*/keymap=\"$KEYMAP\"/" /etc/conf.d/keymaps 2>/dev/null || true

    echo "$NEW_HOSTNAME" > /etc/hostname
    [[ "$INIT" == openrc ]] && echo "hostname=\"$NEW_HOSTNAME\"" > /etc/conf.d/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $NEW_HOSTNAME.localdomain $NEW_HOSTNAME
EOF
}

configure_pacman() {
    step "Configuring pacman (lib32 + Arch extra/multilib for COSMIC, Steam, Discord)"
    local conf=/etc/pacman.conf
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$conf"
    sed -i 's/^#Color$/Color/' "$conf"
    # Artix [lib32] (must stay above Arch [multilib])
    if ! grep -q '^\[lib32\]' "$conf"; then
        if grep -q '^#\[lib32\]$' "$conf"; then
            sed -i '/^#\[lib32\]$/,/^#Include/ s/^#//' "$conf"
        else
            printf '\n[lib32]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$conf"
        fi
    fi

    pacman-key --init
    pacman-key --populate artix
    pacman -Sy --noconfirm
    pac artix-archlinux-support

    # Make sure the Arch mirrorlist has at least one active server.
    local ml=/etc/pacman.d/mirrorlist-arch
    if ! grep -q '^Server' "$ml" 2>/dev/null; then
        printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\nServer = https://fastly.mirror.pkgbuild.com/$repo/os/$arch\n' > "$ml"
    fi
    # Arch repos go *after* all Artix repos.
    grep -q '^\[extra\]' "$conf"    || printf '\n# Arch Linux repositories (artix-archlinux-support)\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> "$conf"
    grep -q '^\[multilib\]' "$conf" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> "$conf"
    pacman-key --populate archlinux
    pacman -Syu --noconfirm
}

create_users() {
    step "Creating user '$NEW_USER'"
    local groups=wheel g
    for g in audio video input storage optical kvm; do getent group "$g" &>/dev/null && groups+=",$g"; done
    id "$NEW_USER" &>/dev/null || useradd -m -G "$groups" -s /bin/bash "$NEW_USER"
    usermod -p "$USER_HASH" "$NEW_USER"
    usermod -p "$ROOT_HASH" root
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel >/dev/null
}

install_gpu() {
    step "Installing graphics drivers: $GPU"
    local pkgs=(mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader) v
    for v in $GPU; do
        case $v in
            amd)    pkgs+=(vulkan-radeon lib32-vulkan-radeon) ;;
            intel)  pkgs+=(vulkan-intel lib32-vulkan-intel intel-media-driver) ;;
            nvidia) pkgs+=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings) ;;
            vm)     pkgs+=(vulkan-swrast lib32-vulkan-swrast) ;;
        esac
    done
    pac_soft "${pkgs[@]}"

    if [[ " $GPU " == *" nvidia "* ]]; then
        # Early KMS for NVIDIA under Wayland; drop the generic kms hook so nouveau stays out of the initramfs.
        sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub
        sed -i '/^HOOKS=/ s/ kms//' /etc/mkinitcpio.conf
    fi
}

install_desktop() {
    step "Installing COSMIC desktop"
    # Audio first so pipewire-jack/-pulse satisfy app dependencies later.
    pac pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    pac_soft lib32-pipewire

    pac cosmic greetd
    pac_soft xdg-desktop-portal-cosmic xdg-user-dirs xdg-utils gnome-keyring \
             noto-fonts noto-fonts-emoji ttf-liberation ttf-dejavu \
             bluez bluez-utils "bluez-$INIT"
}

setup_greeter() {
    step "Setting up cosmic-greeter on $INIT"
    # Arch's package ships systemd units + sysusers/tmpfiles only; do the equivalent by hand.
    if ! getent passwd cosmic-greeter &>/dev/null; then
        useradd --system --user-group --home-dir /var/lib/cosmic-greeter \
                --shell /usr/bin/nologin --comment "Cosmic Greeter Account" cosmic-greeter
    fi
    usermod -aG video cosmic-greeter
    install -dm0750 -o cosmic-greeter -g cosmic-greeter /var/lib/cosmic-greeter

    # greetd config: cosmic-comp + cosmic-greeter on VT7 (keeps tty1 free for a text login)
    [[ -f /etc/greetd/config.toml && ! -f /etc/greetd/config.toml.orig ]] && cp /etc/greetd/config.toml /etc/greetd/config.toml.orig
    install -dm755 /etc/greetd
    cat > /etc/greetd/config.toml <<'EOF'
# Written by artix-cosmic-install.sh -- COSMIC greeter on Artix (no systemd)
[terminal]
vt = 7

[general]
service = "greetd"

[default_session]
command = "cosmic-greeter-start"
user = "cosmic-greeter"
EOF

    # PAM: make sure greetd + greetd-greeter exist and unlock gnome-keyring at login
    if [[ ! -f /etc/pam.d/greetd ]]; then
        cat > /etc/pam.d/greetd <<'EOF'
#%PAM-1.0
auth       include      system-local-login
account    include      system-local-login
password   include      system-local-login
session    include      system-local-login
EOF
    fi
    [[ -f /etc/pam.d/greetd-greeter ]] || cp /etc/pam.d/greetd /etc/pam.d/greetd-greeter
    # PAM evaluates each type (auth/session) in file order, so appending puts
    # gnome-keyring after the existing auth/session stacks.
    grep -q pam_gnome_keyring /etc/pam.d/greetd || cat >> /etc/pam.d/greetd <<'EOF'
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
EOF

    if [[ "$INIT" == dinit ]]; then
        local after_local=""
        [[ -e /etc/dinit.d/local.target ]] && after_local="depends-on = local.target"
        cat > /etc/dinit.d/cosmic-greeter-pre <<EOF
# Creates /run/cosmic-greeter (systemd-tmpfiles does this on Arch)
type = scripted
command = /usr/bin/install -dm0755 -o cosmic-greeter -g cosmic-greeter /run/cosmic-greeter
$after_local
EOF
        cat > /etc/dinit.d/cosmic-greeter-daemon <<'EOF'
# D-Bus service com.system76.CosmicGreeter (user backgrounds etc. on the login screen)
type = process
command = /usr/bin/cosmic-greeter-daemon
smooth-recovery = true
depends-on = dbus
depends-on = cosmic-greeter-pre
EOF
        cat > /etc/dinit.d/cosmic-greeter <<'EOF'
# greetd running the COSMIC greeter
type = process
command = /usr/bin/greetd --config /etc/greetd/config.toml
smooth-recovery = true
depends-on = dbus
depends-on = elogind
depends-on = cosmic-greeter-pre
waits-for = cosmic-greeter-daemon
EOF
    else
        cat > /etc/init.d/cosmic-greeter-daemon <<'EOF'
#!/usr/bin/openrc-run
description="COSMIC greeter D-Bus daemon"
supervisor=supervise-daemon
command=/usr/bin/cosmic-greeter-daemon

depend() {
    need dbus
}

start_pre() {
    checkpath -d -m 0755 -o cosmic-greeter:cosmic-greeter /run/cosmic-greeter
}
EOF
        cat > /etc/init.d/cosmic-greeter <<'EOF'
#!/usr/bin/openrc-run
description="COSMIC greeter (greetd)"
supervisor=supervise-daemon
command=/usr/bin/greetd
command_args="--config /etc/greetd/config.toml"
respawn_delay=2
respawn_max=5

depend() {
    need dbus elogind localmount
    use cosmic-greeter-daemon
    after bootmisc agetty
}

start_pre() {
    checkpath -d -m 0755 -o cosmic-greeter:cosmic-greeter /run/cosmic-greeter
}
EOF
        chmod 755 /etc/init.d/cosmic-greeter /etc/init.d/cosmic-greeter-daemon
    fi
}

setup_audio() {
    step "PipeWire autostart for COSMIC sessions"
    cat > /usr/local/bin/artix-pipewire-start <<'EOF'
#!/bin/sh
# Starts PipeWire for the logged-in user (Artix has no systemd --user).
pgrep -u "$(id -u)" -x pipewire >/dev/null 2>&1 && exit 0
pipewire &
sleep 1
wireplumber &
pipewire-pulse &
wait
EOF
    chmod 755 /usr/local/bin/artix-pipewire-start
    install -dm755 /etc/xdg/autostart
    cat > /etc/xdg/autostart/artix-pipewire.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire (Artix)
Comment=Start PipeWire, WirePlumber and pipewire-pulse
Exec=/usr/local/bin/artix-pipewire-start
NoDisplay=true
Terminal=false
EOF
}

install_apps() {
    step "Installing apps: Audacity, OBS Studio, Steam, Discord ${EXTRA_PKGS}"
    # shellcheck disable=SC2206
    local extra=($EXTRA_PKGS)
    pac_soft audacity obs-studio steam discord "${extra[@]}"
}

enable_services() {
    step "Enabling services ($INIT)"
    if [[ "$INIT" == dinit ]]; then
        enable_service dbus
        enable_service elogind
        enable_service NetworkManager
        enable_service "bluetoothd|bluetooth"
        enable_service cosmic-greeter-daemon
        enable_service cosmic-greeter
    else
        enable_service elogind boot
        enable_service dbus default
        enable_service NetworkManager default
        enable_service "bluetooth|bluetoothd" default
        enable_service cosmic-greeter-daemon default
        enable_service cosmic-greeter default
    fi
}

install_aur() {
    step "AUR: yay, Claude desktop${AUR_EXTRA_PKGS:+, $AUR_EXTRA_PKGS}$([[ "${INSTALL_RESOLVE,,}" == y* ]] && echo ", $RESOLVE_PKG")"
    local tmp_sudo=/etc/sudoers.d/99-artix-installer-temp
    echo "$NEW_USER ALL=(ALL) NOPASSWD: ALL" > "$tmp_sudo"; chmod 440 "$tmp_sudo"

    as_user() { su - "$NEW_USER" -c "$1"; }

    if ! command -v yay &>/dev/null; then
        as_user 'set -e; rm -rf /tmp/yay-bin; git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin; cd /tmp/yay-bin; makepkg -si --noconfirm' \
            || record_failure "AUR: yay-bin (AUR helper) -- Claude desktop and Resolve were skipped too"
    fi

    if command -v yay &>/dev/null; then
        local yayflags="--noconfirm --needed --answerdiff None --answerclean None --removemake"
        as_user "yay -S $yayflags claude-desktop" || record_failure "AUR: claude-desktop"

        local p
        for p in $AUR_EXTRA_PKGS; do   # brave-origin-bin by default
            as_user "yay -S $yayflags $p" || record_failure "AUR: $p"
        done

        if [[ "${INSTALL_RESOLVE,,}" == y* ]]; then
            # OpenCL runtime for Resolve, matched to the GPU
            local cl=() v
            for v in $GPU; do
                case $v in
                    amd)    cl+=(rocm-opencl-runtime) ;;
                    intel)  cl+=(intel-compute-runtime) ;;
                    nvidia) cl+=(opencl-nvidia) ;;
                esac
            done
            ((${#cl[@]})) && pac_soft "${cl[@]}"
            info "Building $RESOLVE_PKG -- this downloads ~3 GB from Blackmagic and can take a while."
            if as_user "yay -S $yayflags $RESOLVE_PKG"; then
                # Studio activation needs a writable license dir
                install -dm0755 -o "$NEW_USER" -g "$NEW_USER" /opt/resolve/.license 2>/dev/null || true
            else
                record_failure "AUR: $RESOLVE_PKG"
            fi
        fi
    fi
    rm -f "$tmp_sudo"
    rm -rf "/home/$NEW_USER/.cache/yay"
}

install_bootloader() {
    step "Building initramfs and installing GRUB ($BOOT_MODE)"
    mkinitcpio -P
    if [[ "$BOOT_MODE" == uefi ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Artix --recheck
        # Fallback path (EFI/BOOT/BOOTX64.EFI) for firmware that forgets NVRAM entries
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
    else
        grub-install --target=i386-pc --recheck "$DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

stage2() {
    # shellcheck source=/dev/null
    source "$CONF_IN_TARGET"
    : > "$FAILED_FILE"
    trap 'rm -f /etc/sudoers.d/99-artix-installer-temp' EXIT
    configure_system
    configure_pacman
    create_users
    install_gpu
    install_desktop
    setup_greeter
    setup_audio
    install_apps
    enable_services
    install_aur
    install_bootloader
    sudo -u "$NEW_USER" xdg-user-dirs-update 2>/dev/null || true
    step "Stage 2 complete"
}

# ------------------------------------------------------------------ main -----
if [[ "${1:-}" == "--stage2" ]]; then
    stage2
else
    stage1
fi
