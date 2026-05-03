#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Lunar — NixOS self-installer (Hyprland + Quickshell rice dhrruvsharma/shell)
#  - LUKS + Btrfs (subvolumes : root / home / nix / log / snapshots)
#  - systemd-boot (UEFI) ou GRUB (BIOS)
#  - configuration.nix declarative + post-install rice deploy
#  - Locale fr_FR / clavier AZERTY latin9
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─ Couleurs / logging ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
MAGENTA='\033[0;35m'; BLUE='\033[0;34m'; WHITE='\033[1;37m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*"; }
log_ok()      { echo -e "${GREEN}[  OK  ]${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
log_err()     { echo -e "${RED}[FAIL]${RESET}    $*"; }
log_section() { echo -e "\n${MAGENTA}${BOLD}── $* ──${RESET}\n"; }
die()         { log_err "$*"; exit 1; }

# ─ Banner ────────────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    cat <<'BANNER'
       ╦  ╦ ╦╔╗╔╔═╗╦═╗  ┌┐┌┬─┐┌─┐┌─┐
       ║  ║ ║║║║╠═╣╠╦╝  ││││┌┘│ ││  
       ╩═╝╚═╝╝╚╝╩ ╩╩╚═  ┘└┘┴┴ └─┘└─┘
BANNER
    echo -e "${RESET}${DIM}     NixOS installer ─ Hyprland + Quickshell rice${RESET}"
    echo -e "${DIM}     LUKS+Btrfs ─ Material You ─ AZERTY latin9${RESET}\n"
}

# ─ Sanity checks ─────────────────────────────────────────────────────────────
sanity_checks() {
    [[ $EUID -eq 0 ]] || die "Doit etre lance en root (sudo -i)."
    [[ -e /etc/NIXOS ]] || die "Pas dans la live ISO NixOS (/etc/NIXOS absent)."
    command -v nixos-install >/dev/null || die "nixos-install introuvable."
    command -v nixos-generate-config >/dev/null || die "nixos-generate-config introuvable."

    if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        log_warn "Pas de connexion reseau detectee."
        log_warn "Configure le wifi avec : sudo systemctl start wpa_supplicant && sudo wpa_cli"
        log_warn "Ou branche un cable ethernet."
        die "Internet requis pour l'install NixOS."
    fi
    log_ok "Sanity checks OK (root + live ISO + reseau)."
}

# ─ Detection firmware (UEFI ou BIOS) ─────────────────────────────────────────
detect_firmware() {
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE="uefi"
        log_ok "Firmware: UEFI (systemd-boot sera utilise)"
    else
        FIRMWARE="bios"
        log_ok "Firmware: BIOS Legacy (GRUB sera utilise)"
    fi
}

# ─ Detection VM ──────────────────────────────────────────────────────────────
detect_vm() {
    IS_VM=false
    VM_TYPE="none"
    if systemd-detect-virt -q 2>/dev/null; then
        IS_VM=true
        VM_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"
        log_info "Environnement VM detecte: ${VM_TYPE}"
    else
        log_info "Baremetal."
    fi
}

# ─ Selection disque ──────────────────────────────────────────────────────────
select_disk() {
    log_section "SELECTION DU DISQUE CIBLE"
    echo -e "${WHITE}Disques disponibles :${RESET}\n"
    mapfile -t DISKS < <(lsblk -dno NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{print $0}')
    if [[ ${#DISKS[@]} -eq 0 ]]; then
        die "Aucun disque detecte."
    fi
    local i=1
    for d in "${DISKS[@]}"; do
        local name size model
        name=$(echo "$d" | awk '{print $1}')
        size=$(echo "$d" | awk '{print $2}')
        model=$(echo "$d" | awk '{$1=""; $2=""; $3=""; print}' | sed 's/^[[:space:]]*//')
        echo -e "  ${CYAN}[$i]${RESET}  /dev/${name}  ${GREEN}${size}${RESET}  ${DIM}${model}${RESET}"
        ((i++))
    done
    echo
    local choice
    while true; do
        read -rp "$(echo -e "${BOLD}Choix [1-${#DISKS[@]}] :${RESET} ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DISKS[@]} )); then
            TARGET_DISK="/dev/$(echo "${DISKS[$((choice-1))]}" | awk '{print $1}')"
            break
        fi
        log_warn "Choix invalide."
    done

    echo -e "\n${RED}${BOLD}ATTENTION :${RESET} ${TARGET_DISK} sera ${BOLD}ECRASE INTEGRALEMENT${RESET}."
    read -rp "Tape 'OUI' pour confirmer : " confirm
    [[ "$confirm" == "OUI" ]] || die "Annule."
    log_ok "Disque cible : ${TARGET_DISK}"
}

# ─ Prompts utilisateur ───────────────────────────────────────────────────────
prompt_user_info() {
    log_section "INFORMATIONS UTILISATEUR"
    read -rp "$(echo -e "${BOLD}Nom utilisateur${RESET} (minuscules, sans espace) : ")" USERNAME
    [[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || die "Nom invalide."

    read -rp "$(echo -e "${BOLD}Hostname${RESET} (defaut: lunaris) : ")" HOSTNAME
    HOSTNAME="${HOSTNAME:-lunaris}"

    while true; do
        read -rsp "$(echo -e "${BOLD}Mot de passe utilisateur :${RESET} ")" USER_PASS; echo
        read -rsp "$(echo -e "${BOLD}Confirmation :${RESET} ")" USER_PASS2; echo
        [[ "$USER_PASS" == "$USER_PASS2" && -n "$USER_PASS" ]] && break
        log_warn "Les mots de passe ne correspondent pas (ou vide)."
    done

    while true; do
        read -rsp "$(echo -e "${BOLD}Passphrase LUKS${RESET} (chiffrement disque) : ")" LUKS_PASS; echo
        read -rsp "$(echo -e "${BOLD}Confirmation :${RESET} ")" LUKS_PASS2; echo
        [[ "$LUKS_PASS" == "$LUKS_PASS2" && ${#LUKS_PASS} -ge 8 ]] && break
        log_warn "Passphrase trop courte (min 8) ou ne correspondent pas."
    done

    log_ok "Utilisateur : ${USERNAME} / Host : ${HOSTNAME}"
}

# ─ Recap avant destruction ───────────────────────────────────────────────────
recap() {
    log_section "RECAPITULATIF"
    echo -e "  ${WHITE}Disque cible      :${RESET}  ${BOLD}${TARGET_DISK}${RESET}"
    echo -e "  ${WHITE}Firmware          :${RESET}  ${BOLD}${FIRMWARE}${RESET}"
    echo -e "  ${WHITE}Utilisateur       :${RESET}  ${BOLD}${USERNAME}${RESET}"
    echo -e "  ${WHITE}Hostname          :${RESET}  ${BOLD}${HOSTNAME}${RESET}"
    echo -e "  ${WHITE}VM detectee       :${RESET}  ${BOLD}${IS_VM} (${VM_TYPE})${RESET}"
    echo -e "  ${WHITE}Layout            :${RESET}  ${BOLD}LUKS + Btrfs (root, home, nix, log, snapshots)${RESET}"
    echo -e "  ${WHITE}Bureau            :${RESET}  ${BOLD}Hyprland + Quickshell rice (dhrruvsharma/shell)${RESET}"
    echo -e "  ${WHITE}Locale / Clavier  :${RESET}  ${BOLD}fr_FR.UTF-8 / AZERTY latin9${RESET}\n"
    read -rp "$(echo -e "${BOLD}Lancer l'install ? Tape 'GO' :${RESET} ")" go
    [[ "$go" == "GO" ]] || die "Annule."
}

# ─ Partitionnement + LUKS + Btrfs ────────────────────────────────────────────
partition_disk() {
    log_section "PARTITIONNEMENT"
    log_info "Wipe ${TARGET_DISK}..."
    swapoff -a 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    wipefs -af "${TARGET_DISK}"
    sgdisk --zap-all "${TARGET_DISK}" >/dev/null

    if [[ "$FIRMWARE" == "uefi" ]]; then
        sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"ESP" "${TARGET_DISK}"
        sgdisk -n 2:0:0   -t 2:8309 -c 2:"cryptroot" "${TARGET_DISK}"
    else
        sgdisk -n 1:0:+1G -t 1:8300 -c 1:"boot" "${TARGET_DISK}"
        sgdisk -n 2:0:0   -t 2:8309 -c 2:"cryptroot" "${TARGET_DISK}"
        sgdisk -A 1:set:2 "${TARGET_DISK}"
    fi
    partprobe "${TARGET_DISK}"
    sleep 2

    if [[ "${TARGET_DISK}" =~ nvme|mmcblk ]]; then
        ESP_PART="${TARGET_DISK}p1"
        CRYPT_PART="${TARGET_DISK}p2"
    else
        ESP_PART="${TARGET_DISK}1"
        CRYPT_PART="${TARGET_DISK}2"
    fi
    log_ok "Partitions : boot=${ESP_PART}  cryptroot=${CRYPT_PART}"

    log_info "Chiffrement LUKS2 (argon2id)..."
    echo -n "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 \
        --pbkdf argon2id --pbkdf-memory 1048576 --pbkdf-parallel 4 --iter-time 5000 \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --batch-mode "${CRYPT_PART}" -
    echo -n "${LUKS_PASS}" | cryptsetup open "${CRYPT_PART}" cryptroot -
    log_ok "LUKS ouvert : /dev/mapper/cryptroot"

    log_info "Format Btrfs + subvolumes..."
    mkfs.btrfs -f -L nixos /dev/mapper/cryptroot >/dev/null
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@         >/dev/null
    btrfs subvolume create /mnt/@home     >/dev/null
    btrfs subvolume create /mnt/@nix      >/dev/null
    btrfs subvolume create /mnt/@log      >/dev/null
    btrfs subvolume create /mnt/@snapshots >/dev/null
    umount /mnt

    if [[ "$FIRMWARE" == "uefi" ]]; then
        mkfs.fat -F32 -n EFI "${ESP_PART}" >/dev/null
    else
        mkfs.ext4 -F -L boot "${ESP_PART}" >/dev/null
    fi

    local btrfs_opts="noatime,compress=zstd:3,space_cache=v2,ssd"
    mount -o "${btrfs_opts},subvol=@"          /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/{home,nix,var/log,boot,.snapshots}
    mount -o "${btrfs_opts},subvol=@home"      /dev/mapper/cryptroot /mnt/home
    mount -o "${btrfs_opts},subvol=@nix"       /dev/mapper/cryptroot /mnt/nix
    mount -o "${btrfs_opts},subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
    mount -o "${btrfs_opts},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
    mount "${ESP_PART}" /mnt/boot

    log_ok "Subvolumes montes (root, home, nix, var/log, snapshots, boot)"
}

# ─ Genere hardware-configuration.nix puis configuration.nix ──────────────────
generate_nix_config() {
    log_section "GENERATION CONFIGURATION NIXOS"
    nixos-generate-config --root /mnt
    log_ok "hardware-configuration.nix genere"

    LUKS_UUID="$(blkid -s UUID -o value "${CRYPT_PART}")"

    local boot_loader_block
    if [[ "$FIRMWARE" == "uefi" ]]; then
        boot_loader_block='
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.editor = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot";'
    else
        boot_loader_block="
  boot.loader.grub.enable = true;
  boot.loader.grub.device = \"${TARGET_DISK}\";
  boot.loader.grub.useOSProber = true;"
    fi

    local vm_block=""
    if [[ "$IS_VM" == true ]]; then
        case "$VM_TYPE" in
            vmware)
                vm_block='
  virtualisation.vmware.guest.enable = true;
  services.xserver.videoDrivers = [ "vmware" ];'
                ;;
            kvm|qemu)
                vm_block='
  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;'
                ;;
            oracle|virtualbox)
                vm_block='
  virtualisation.virtualbox.guest.enable = true;
  virtualisation.virtualbox.guest.x11 = true;'
                ;;
        esac
    fi

    cat > /mnt/etc/nixos/configuration.nix <<NIXCFG
{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # ── Bootloader ──${boot_loader_block}

  # ── LUKS ──
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/${LUKS_UUID}";
    preLVM = true;
    allowDiscards = true;
  };

  # ── Kernel ──
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.supportedFilesystems = [ "btrfs" ];
  boot.kernelParams = [ "quiet" "splash" ];

  # ── Reseau ──
  networking.hostName = "${HOSTNAME}";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # ── Localisation ──
  time.timeZone = "Europe/Paris";
  i18n.defaultLocale = "fr_FR.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS        = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT    = "fr_FR.UTF-8";
    LC_MONETARY       = "fr_FR.UTF-8";
    LC_NAME           = "fr_FR.UTF-8";
    LC_NUMERIC        = "fr_FR.UTF-8";
    LC_PAPER          = "fr_FR.UTF-8";
    LC_TELEPHONE      = "fr_FR.UTF-8";
    LC_TIME           = "fr_FR.UTF-8";
  };
  console.keyMap = "fr-latin9";
  services.xserver.xkb = {
    layout  = "fr";
    variant = "latin9";
    options = "caps:escape,compose:ralt";
  };

  # ── Hyprland (Wayland) ──
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };
  programs.hyprlock.enable = true;
  services.hypridle.enable = true;

  # ── XDG portals ──
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-hyprland
      xdg-desktop-portal-gtk
    ];
  };

  # ── Audio (Pipewire) ──
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
  };

  # ── Bluetooth ──
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # ── Polkit + display manager (greetd + tuigreet) ──
  security.polkit.enable = true;
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "\${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --asterisks --cmd Hyprland";
        user    = "greeter";
      };
    };
  };

  # ── Utilisateur ──
  users.users.${USERNAME} = {
    isNormalUser = true;
    description  = "${USERNAME}";
    extraGroups  = [ "wheel" "networkmanager" "audio" "video" "input" "storage" "lp" ];
    shell        = pkgs.bash;
  };
  security.sudo.wheelNeedsPassword = true;

  # ── Polices (Quickshell rice) ──
  fonts.packages = with pkgs; [
    nerd-fonts.iosevka
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
    material-symbols
    material-icons
    inter
  ];

  # ── Variables d'environnement ──
  environment.sessionVariables = {
    NIXOS_OZONE_WL                       = "1";
    QT_QPA_PLATFORM                      = "wayland;xcb";
    QT_QPA_PLATFORMTHEME                 = "qt6ct";
    QT_WAYLAND_DISABLE_WINDOWDECORATION  = "1";
    GDK_BACKEND                          = "wayland,x11,*";
    SDL_VIDEODRIVER                      = "wayland";
    MOZ_ENABLE_WAYLAND                   = "1";
    XCURSOR_SIZE                         = "24";
    HYPRCURSOR_SIZE                      = "24";
  };

  # ── Paquets systeme ──
  environment.systemPackages = with pkgs; [
    # rice / quickshell stack
    quickshell
    matugen
    cava
    kitty
    rofi-wayland
    waybar
    mako
    swww
    grimblast
    grim
    slurp
    wl-clipboard
    cliphist
    wf-recorder
    brightnessctl
    playerctl
    pamixer
    pavucontrol
    wlr-randr
    hyprpicker

    # apps utilisateur
    xfce.thunar
    xfce.thunar-archive-plugin
    xfce.thunar-volman
    file-roller
    gvfs
    networkmanagerapplet
    blueman
    kdePackages.kdeconnect-kde
    qt6ct
    libsForQt5.qt5ct
    libsForQt5.qtstyleplugin-kvantum
    nwg-look
    polkit_gnome

    # CLI / dev
    git
    curl
    wget
    jq
    ripgrep
    fd
    bat
    eza
    fzf
    htop
    btop
    tmux
    neovim
    nano
    starship
    upower
    socat
    unzip
    p7zip
    imagemagick

    # GTK / theming
    adw-gtk3
    gnome-themes-extra
    papirus-icon-theme
    bibata-cursors

    # gaming
    mangohud
    gamemode
  ];

  programs.dconf.enable = true;
  services.gvfs.enable     = true;
  services.udisks2.enable  = true;
  services.tumbler.enable  = true;

  # ── Nix flakes / GC ──
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store   = true;
  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 14d";
  };

${vm_block}
  system.stateVersion = "24.11";
}
NIXCFG

    log_ok "configuration.nix ecrite (~$(wc -l < /mnt/etc/nixos/configuration.nix) lignes)"
}

# ─ Lancement nixos-install ───────────────────────────────────────────────────
run_nixos_install() {
    log_section "NIXOS-INSTALL (peut prendre 20-60 min selon CPU/reseau)"
    log_info "nixos-install --no-root-passwd ..."
    if ! nixos-install --no-root-passwd --root /mnt 2>&1 | tee /tmp/nixos-install.log; then
        die "nixos-install a echoue. Voir /tmp/nixos-install.log"
    fi
    log_ok "nixos-install termine."

    log_info "Configuration mot de passe utilisateur..."
    echo "${USERNAME}:${USER_PASS}" | nixos-enter --root /mnt -c "chpasswd"
    log_ok "Mot de passe defini pour ${USERNAME}"
}

# ─ Deploy rice dhrruvsharma/shell ────────────────────────────────────────────
deploy_rice() {
    log_section "DEPLOIEMENT RICE (dhrruvsharma/shell)"

    # Heredoc unquoted (variables expansees ICI). On echappe \$ pour les vars que le sous-shell consomme.
    nixos-enter --root /mnt -c "bash -e" <<RICESH || log_warn "Deploy rice partiellement echoue (non-critique)"
set -uo pipefail
USERNAME="${USERNAME}"
RICE_REPO="https://github.com/dhrruvsharma/shell.git"
RICE_TMP="/tmp/lunaris-rice"
USER_HOME="/home/\${USERNAME}"
USER_CFG="\${USER_HOME}/.config"
HYPR_DIR="\${USER_CFG}/hypr"

if ! id "\${USERNAME}" >/dev/null 2>&1; then
    echo "[FAIL] User \${USERNAME} introuvable - skip rice."
    exit 1
fi

mkdir -p "\${USER_CFG}" "\${HYPR_DIR}" "\${USER_HOME}/Pictures/wallpapers" \\
         "\${USER_HOME}/Pictures/Screenshots" "\${USER_HOME}/Videos/recordings"

rm -rf "\${RICE_TMP}"
if ! sudo -u "\${USERNAME}" git clone --depth 1 "\${RICE_REPO}" "\${RICE_TMP}"; then
    echo "[WARN] Clone du rice echoue - skip."
    exit 1
fi

for dir in cava kitty matugen quickshell rofi scripts; do
    if [[ -d "\${RICE_TMP}/\${dir}" ]]; then
        mkdir -p "\${USER_CFG}/\${dir}"
        cp -r "\${RICE_TMP}/\${dir}/." "\${USER_CFG}/\${dir}/"
    fi
done

[[ -f "\${RICE_TMP}/hypr/colors.conf"   ]] && cp "\${RICE_TMP}/hypr/colors.conf"   "\${HYPR_DIR}/colors.conf"
[[ -f "\${RICE_TMP}/hypr/hyprlock.conf" ]] && cp "\${RICE_TMP}/hypr/hyprlock.conf" "\${HYPR_DIR}/hyprlock.conf"

# Hyprland.conf modulaire (AZERTY + locale + IPC quickshell + autostart rice)
cat > "\${HYPR_DIR}/hyprland.conf" <<'HYPRMAIN'
# Lunar - Hyprland config (rice dhrruvsharma/shell + AZERTY)
source = ~/.config/hypr/colors.conf

monitor = , preferred, auto, 1

input {
    kb_layout  = fr
    kb_variant = latin9
    kb_options = caps:escape,compose:ralt
    follow_mouse = 1
    sensitivity = 0
    accel_profile = flat
    touchpad {
        natural_scroll = true
        tap-to-click = true
        disable_while_typing = true
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 2
    col.active_border = rgba(89b4faee) rgba(cba6f7ee) 45deg
    col.inactive_border = rgba(313244aa)
    layout = dwindle
    resize_on_border = true
    allow_tearing = true
}

decoration {
    rounding = 12
    blur {
        enabled = true
        size = 6
        passes = 2
        new_optimizations = true
        vibrancy = 0.2
    }
    shadow {
        enabled = true
        range = 16
        render_power = 3
        color = rgba(1a1a2eee)
    }
    dim_inactive = true
    dim_strength = 0.08
}

animations {
    enabled = true
    bezier  = wind, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 4, wind, slide
    animation = border, 1, 2, default
    animation = fade, 1, 4, default
    animation = workspaces, 1, 4, wind
}

dwindle {
    pseudotile = true
    preserve_split = true
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    vfr = true
    vrr = 1
    enable_swallow = true
    swallow_regex = ^(kitty|Alacritty)$
    focus_on_activate = true
}

cursor {
    no_hardware_cursors = true
    enable_hyprcursor = true
}

xwayland {
    force_zero_scaling = true
}

$mainMod = SUPER
$terminal = kitty
$fileManager = thunar

# Apps
bind = $mainMod, Return, exec, $terminal
bind = $mainMod, E, exec, $fileManager
bind = $mainMod, V, exec, cliphist list | rofi -dmenu | cliphist decode | wl-copy

# Quickshell IPC (rice panels)
bind = $mainMod SHIFT, D, exec, qs ipc call launcherWindow toggle
bind = $mainMod SHIFT, W, exec, qs ipc call wallhavenPanel toggle
bind = $mainMod SHIFT, N, exec, qs ipc call networkPanel changeVisible
bind = $mainMod SHIFT, C, exec, qs ipc call controlCenter changeVisible
bind = $mainMod, I, exec, qs ipc call systemPanel toggle
bind = $mainMod, K, exec, kdeconnect-app

# Window mgmt
bind = $mainMod, Q, killactive
bind = $mainMod SHIFT, Q, exit
bind = $mainMod, F, fullscreen, 1
bind = $mainMod, Space, togglefloating
bind = $mainMod, J, togglesplit
bind = $mainMod, L, exec, hyprlock
bind = $mainMod, R, exec, hyprctl reload && pkill -SIGUSR2 waybar

# Focus
bind = $mainMod, left,  movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up,    movefocus, u
bind = $mainMod, down,  movefocus, d

# Move windows
bind = $mainMod SHIFT, left,  movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up,    movewindow, u
bind = $mainMod SHIFT, down,  movewindow, d

# Workspaces (AZERTY)
bind = $mainMod, ampersand,  workspace, 1
bind = $mainMod, eacute,     workspace, 2
bind = $mainMod, quotedbl,   workspace, 3
bind = $mainMod, apostrophe, workspace, 4
bind = $mainMod, parenleft,  workspace, 5
bind = $mainMod SHIFT, ampersand,  movetoworkspace, 1
bind = $mainMod SHIFT, eacute,     movetoworkspace, 2
bind = $mainMod SHIFT, quotedbl,   movetoworkspace, 3
bind = $mainMod SHIFT, apostrophe, movetoworkspace, 4
bind = $mainMod SHIFT, parenleft,  movetoworkspace, 5

# Mouse
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow
bind  = $mainMod, mouse_down, workspace, e+1
bind  = $mainMod, mouse_up,   workspace, e-1

# Media keys
bindel = , XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = , XF86AudioLowerVolume, exec, pamixer -d 5
bindl  = , XF86AudioMute,        exec, pamixer -t
bindl  = , XF86AudioPlay,        exec, playerctl play-pause
bindl  = , XF86AudioNext,        exec, playerctl next
bindl  = , XF86AudioPrev,        exec, playerctl previous
bindel = , XF86MonBrightnessUp,   exec, brightnessctl set +5%
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-

# Screenshots
bind = , Print,        exec, grimblast copysave area
bind = SHIFT, Print,   exec, grimblast copysave output
bind = CTRL, Print,    exec, grimblast copy area

# Window rules
windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(nm-connection-editor)$
windowrulev2 = float, class:^(blueman-manager)$
windowrulev2 = opacity 0.92 0.88, class:^(kitty)$
windowrulev2 = opacity 0.95 0.90, class:^(thunar)$

# Layer rules
layerrule = blur, rofi
layerrule = blur, waybar
layerrule = blur, notifications
layerrule = ignorezero, rofi

# Autostart
exec-once = nm-applet --indicator
exec-once = blueman-applet
exec-once = kdeconnectd
exec-once = mako
exec-once = wl-paste --type text  --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = swww-daemon
exec-once = sleep 1 && swww img $HOME/Pictures/wallpapers/default.jpg --transition-type none 2>/dev/null
exec-once = /run/current-system/sw/libexec/polkit-gnome-authentication-agent-1
# Quickshell rice (fallback waybar si crash)
exec-once = sh -c 'command -v qs >/dev/null && qs & sleep 3; pgrep -x qs >/dev/null || (command -v waybar >/dev/null && waybar)'
# Auto-reload waybar sur changement de moniteur
exec-once = sh -c 'socat -u UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" - | while read -r l; do case "$l" in monitoradded*|monitorremoved*|configreloaded*) pkill -SIGUSR2 waybar ;; esac; done'
HYPRMAIN

# Patch des chemins hardcodes /home/igris/ -> /home/USERNAME/
grep -rl "/home/igris/" "\${USER_CFG}" 2>/dev/null \\
    | xargs -r sed -i "s|/home/igris/|\${USER_HOME}/|g"

# Permissions
chown -R "\${USERNAME}:users" "\${USER_CFG}" "\${USER_HOME}/Pictures" "\${USER_HOME}/Videos" 2>/dev/null || true
chmod +x "\${USER_CFG}/scripts/"*.sh 2>/dev/null || true
find "\${USER_CFG}/quickshell" -name "*.sh" -exec chmod +x {} \\; 2>/dev/null || true

# Wallpaper par defaut + matugen
WALLP="\${USER_HOME}/Pictures/wallpapers/default.jpg"
if [[ ! -f "\${WALLP}" ]] && command -v convert &>/dev/null; then
    sudo -u "\${USERNAME}" convert -size 1920x1080 \\
        gradient:'#1a1a2e-#cba6f7' "\${WALLP}" 2>/dev/null || \\
        sudo -u "\${USERNAME}" convert -size 1920x1080 xc:'#1a1a2e' "\${WALLP}" 2>/dev/null || true
fi
if command -v matugen &>/dev/null && [[ -f "\${WALLP}" ]]; then
    sudo -u "\${USERNAME}" matugen image "\${WALLP}" 2>/dev/null || true
fi

# Cache fonts
sudo -u "\${USERNAME}" fc-cache -f 2>/dev/null || true

echo "[OK] Rice deployee dans \${USER_CFG}"
RICESH

    log_ok "Rice dhrruvsharma/shell deployee."
}

# ─ Menu final ────────────────────────────────────────────────────────────────
final_menu() {
    log_section "INSTALLATION TERMINEE"
    echo -e "${GREEN}${BOLD}  Le systeme est pret.${RESET}\n"
    echo -e "  ${WHITE}Au prochain boot :${RESET}"
    echo -e "    1. Saisis la passphrase LUKS"
    echo -e "    2. tuigreet te connecte sur Hyprland"
    echo -e "    3. Quickshell (rice dhrruvsharma) demarre automatiquement"
    echo -e "    4. ${CYAN}Super+Shift+D${RESET} ouvre le launcher Material You\n"

    echo -e "  ${WHITE}[1]${RESET} Reboot"
    echo -e "  ${WHITE}[2]${RESET} Entrer dans le systeme installe (nixos-enter)"
    echo -e "  ${WHITE}[3]${RESET} Quitter (rester sur la live ISO)\n"
    read -rp "$(echo -e "${BOLD}Choix [1-3] :${RESET} ")" choice
    case "$choice" in
        1) umount -R /mnt 2>/dev/null || true
           cryptsetup close cryptroot 2>/dev/null || true
           reboot ;;
        2) nixos-enter --root /mnt ;;
        *) log_info "Tu peux umount + reboot manuellement quand pret." ;;
    esac
}

# ─ Main ──────────────────────────────────────────────────────────────────────
main() {
    banner
    sanity_checks
    detect_firmware
    detect_vm
    select_disk
    prompt_user_info
    recap
    partition_disk
    generate_nix_config
    run_nixos_install
    deploy_rice
    final_menu
}

main "$@"
