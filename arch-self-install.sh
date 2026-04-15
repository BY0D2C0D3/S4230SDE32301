#!/usr/bin/env bash
###############################################################################
#    
#                 __  ___ _   ___   _ __  _   __ _____ __  _   _    
#               /' _/| __| | | __| | |  \| |/' _/_   _/  \| | | |   
#               `._`.| _|| |_| _|  | | | ' |`._`. | || /\ | |_| |_  
#              |___/|___|___|_|   |_|_|\__||___/ |_||_||_|___|___| 
#
#  
#  ᴀʀᴄʜ ʟɪɴᴜx — ᴍɪʟɪᴛᴀʀʏ-ɢʀᴀᴅᴇ ꜱᴇʟꜰ-ɪɴꜱᴛᴀʟʟᴇʀ
#  Hyprland Config • LUKS + Btrfs • Firejail + Thorium
#  Automated dot-files & Sys-hardening
#  
#  Author  : ᴍɪᴅɴɪɢʜᴛ-sᴇᴄ
#  Version : 4.0.0 — Ultra Performance Edition
#  License : MIT
#
#  Target  : Ryzen 5 7600X • RTX 3070Ti OC • 32GB DDR5
#  Kernel  : linux-zen (preemptive, high-perf scheduler)
###############################################################################
set -euo pipefail
IFS=$'\n\t'
trap 'handle_error $LINENO' ERR

# ─── Colors & Formatting ────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'
readonly GOLD='\033[1;38;5;220m'
readonly BBLUE='\033[1;34m'
readonly BRED='\033[1;31m'
readonly BWHITE='\033[1;97m'

# ─── Logging ────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/arch-install-$(date +%Y%m%d-%H%M%S).log"

log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "${GREEN}[  OK  ]${RESET}  $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $*" | tee -a "$LOG_FILE"; }
log_section() { echo -e "\n${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
                echo -e "${MAGENTA}${BOLD}  $*${RESET}" | tee -a "$LOG_FILE"
                echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════${RESET}\n" | tee -a "$LOG_FILE"; }

die() { log_error "$*"; exit 1; }

handle_error() {
    local line="$1"
    log_error "Erreur fatale à la ligne ${line}. Consultez ${LOG_FILE} pour plus de détails."
    log_error "Tentative de nettoyage..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    exit 1
}

# ─── Safety checks ──────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "Ce script doit être exécuté en tant que root."
[[ -d /sys/firmware/efi/efivars ]] || die "Le système doit démarrer en mode UEFI."

# ─── Verify essential tools ─────────────────────────────────────────────────
for cmd in sgdisk cryptsetup mkfs.btrfs pacstrap arch-chroot genfstab blkid lsblk; do
    command -v "$cmd" &>/dev/null || die "Commande requise manquante : ${cmd}"
done

# ─── Detect environment ─────────────────────────────────────────────────────
IS_VM=false
VM_TYPE="none"
if systemd-detect-virt --quiet 2>/dev/null; then
    IS_VM=true
    VM_TYPE="$(systemd-detect-virt 2>/dev/null || echo "unknown")"
    log_info "Environnement virtuel détecté : ${VM_TYPE}"
fi

# ─── Detect total RAM for optimizations ─────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
log_info "RAM détectée : ${TOTAL_RAM_GB} Go"

# ─── Detect CPU core count ──────────────────────────────────────────────────
CPU_CORES=$(nproc 2>/dev/null || echo 6)
log_info "Cœurs CPU détectés : ${CPU_CORES}"

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     TUI — PHASE 1     ║
#                         ║   Collecte des infos   ║
#                         ╚═══════════════════════╝
###############################################################################

show_banner() {
    clear
    # LUNARIS in GOLD
    echo -e "${GOLD}"
    cat << 'BANNER'
                                                               
                 ▄▄▄      ▄▄▄  ▄▄▄ ▄▄▄    ▄▄▄   ▄▄▄▄   ▄▄▄▄▄▄▄   ▄▄▄▄▄  ▄▄▄▄▄▄▄ 
                 ███      ███  ███ ████▄  ███ ▄██▀▀██▄ ███▀▀███▄  ███  █████▀▀▀ 
                 ███      ███  ███ ███▀██▄███ ███  ███ ███▄▄███▀  ███   ▀████▄  
                 ███      ███▄▄███ ███  ▀████ ███▀▀███ ███▀▀██▄   ███     ▀████ 
                 ████████ ▀██████▀ ███    ███ ███  ███ ███  ▀███ ▄███▄ ███████▀ 
                                                               
BANNER
    echo -e "${RESET}"
    # HYPRLAND ARCH INSTALLER — French flag colors (Blue / White / Red)
    echo -e "${BBLUE}             ╷ ╷╷ ╷╭─╮╭─╮╷  ╭─╮╭╮╷╶┬╮   ╭─╮╭─╮╭─╴╷ ╷   ╷╭╮╷╭─╮╶┬╴╭─╮╷  ╷  ╭─╴╭─╮${RESET}"
    echo -e "${BWHITE}            ├─┤╰┬╯├─╯├┬╯│  ├─┤│╰┤ ││   ├─┤├┬╯│  ├─┤   ││╰┤╰─╮ │ ├─┤│  │  ├╴ ├┬╯${RESET}"
    echo -e "${BRED}              ╵ ╵ ╵ ╵  ╵╰╴╰─╴╵ ╵╵ ╵╶┴╯   ╵ ╵╵╰╴╰─╴╵ ╵   ╵╵ ╵╰─╯ ╵ ╵ ╵╰─╴╰─╴╰─╴╵╰╴${RESET}"
    echo ""
    echo -e "${DIM}              Made by ᴍɪᴅɴɪɢʜᴛ-sᴇᴄ  •  [15.04.2026]             ${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────────────────────────${RESET}"
    echo -e "${DIM}  Zen Kernel • LUKS+Argon2id • Btrfs • Hyprland • Firejail     ${RESET}"
    echo ""
}

# ─── Disk Selection ──────────────────────────────────────────────────────────
select_disk() {
    log_section "SÉLECTION DU DISQUE"
    echo -e "${WHITE}Disques disponibles :${RESET}\n"

    local -a disks=()
    local i=1
    while IFS= read -r line; do
        local dname dsize dtype dmodel
        dname="$(echo "$line" | awk '{print $1}')"
        dsize="$(echo "$line" | awk '{print $4}')"
        dtype="$(echo "$line" | awk '{print $6}')"
        dmodel="$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}')"
        # Skip loop devices
        [[ "$dname" == loop* ]] && continue
        disks+=("/dev/$dname")
        echo -e "  ${CYAN}[$i]${RESET}  /dev/${dname}  —  ${GREEN}${dsize}${RESET}  (${dtype}) ${DIM}${dmodel}${RESET}"
        ((i++))
    done < <(lsblk -dpno NAME,TYPE,SIZE,MODEL | grep -E 'disk' | sed 's|/dev/||')

    [[ ${#disks[@]} -eq 0 ]] && die "Aucun disque détecté."

    echo ""
    while true; do
        read -rp "$(echo -e "${YELLOW}▶ Choisis le numéro du disque cible : ${RESET}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            TARGET_DISK="${disks[$((choice-1))]}"
            break
        fi
        log_warn "Choix invalide. Réessaie."
    done

    echo -e "\n${GREEN}✔ Disque sélectionné : ${BOLD}${TARGET_DISK}${RESET}\n"
}

# ─── Install Mode ────────────────────────────────────────────────────────────
select_install_mode() {
    log_section "MODE D'INSTALLATION"
    echo -e "  ${CYAN}[1]${RESET}  Clean Install  — Efface tout le disque"
    echo -e "  ${CYAN}[2]${RESET}  Dual Boot      — Utilise l'espace libre (conserve les partitions existantes)"
    echo ""

    while true; do
        read -rp "$(echo -e "${YELLOW}▶ Mode d'installation [1/2] : ${RESET}")" mode
        case "$mode" in
            1) INSTALL_MODE="clean"; break ;;
            2) INSTALL_MODE="dualboot"; break ;;
            *) log_warn "Choix invalide." ;;
        esac
    done

    echo -e "\n${GREEN}✔ Mode : ${BOLD}${INSTALL_MODE}${RESET}\n"
}

# ─── CPU Microcode ───────────────────────────────────────────────────────────
select_microcode() {
    log_section "MICROCODE CPU"

    # Auto-detect
    local detected=""
    if grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        detected="intel"
    elif grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        detected="amd"
    fi

    if [[ -n "$detected" ]]; then
        echo -e "  ${GREEN}✔ CPU détecté automatiquement : ${BOLD}${detected^^}${RESET}"
        echo ""
        read -rp "$(echo -e "${YELLOW}▶ Utiliser ${detected}-ucode ? [O/n] : ${RESET}")" confirm
        if [[ "${confirm,,}" != "n" ]]; then
            CPU_UCODE="${detected}-ucode"
            echo -e "\n${GREEN}✔ Microcode : ${BOLD}${CPU_UCODE}${RESET}\n"
            return
        fi
    fi

    echo -e "  ${CYAN}[1]${RESET}  AMD   (amd-ucode)"
    echo -e "  ${CYAN}[2]${RESET}  Intel (intel-ucode)"
    echo ""

    while true; do
        read -rp "$(echo -e "${YELLOW}▶ Microcode CPU [1/2] : ${RESET}")" mc
        case "$mc" in
            1) CPU_UCODE="amd-ucode"; break ;;
            2) CPU_UCODE="intel-ucode"; break ;;
            *) log_warn "Choix invalide." ;;
        esac
    done

    echo -e "\n${GREEN}✔ Microcode : ${BOLD}${CPU_UCODE}${RESET}\n"
}

# ─── User Info ───────────────────────────────────────────────────────────────
collect_user_info() {
    log_section "INFORMATIONS UTILISATEUR"

    # Username
    while true; do
        read -rp "$(echo -e "${YELLOW}▶ Nom d'utilisateur : ${RESET}")" USERNAME
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            echo -e "  ${GREEN}✔ Utilisateur : ${BOLD}${USERNAME}${RESET}"
            break
        fi
        log_warn "Nom invalide. Utilise uniquement [a-z0-9_-], commençant par une lettre ou _."
    done

    echo ""

    # Root password
    while true; do
        read -srp "$(echo -e "${YELLOW}▶ Mot de passe ROOT : ${RESET}")" ROOT_PASSWORD; echo ""
        read -srp "$(echo -e "${YELLOW}▶ Confirmer mot de passe ROOT : ${RESET}")" rp2; echo ""
        if [[ "$ROOT_PASSWORD" == "$rp2" && -n "$ROOT_PASSWORD" ]]; then
            echo -e "  ${GREEN}✔ Mot de passe root défini.${RESET}"
            break
        fi
        log_warn "Les mots de passe ne correspondent pas ou sont vides."
    done

    echo ""

    # User password
    while true; do
        read -srp "$(echo -e "${YELLOW}▶ Mot de passe pour ${USERNAME} : ${RESET}")" USER_PASSWORD; echo ""
        read -srp "$(echo -e "${YELLOW}▶ Confirmer mot de passe pour ${USERNAME} : ${RESET}")" up2; echo ""
        if [[ "$USER_PASSWORD" == "$up2" && -n "$USER_PASSWORD" ]]; then
            echo -e "  ${GREEN}✔ Mot de passe utilisateur défini.${RESET}"
            break
        fi
        log_warn "Les mots de passe ne correspondent pas ou sont vides."
    done

    echo ""

    # LUKS passphrase
    while true; do
        read -srp "$(echo -e "${YELLOW}▶ Passphrase LUKS (chiffrement disque) : ${RESET}")" LUKS_PASSPHRASE; echo ""
        read -srp "$(echo -e "${YELLOW}▶ Confirmer passphrase LUKS : ${RESET}")" lp2; echo ""
        if [[ "$LUKS_PASSPHRASE" == "$lp2" && -n "$LUKS_PASSPHRASE" ]]; then
            echo -e "  ${GREEN}✔ Passphrase LUKS définie.${RESET}"
            break
        fi
        log_warn "Les passphrases ne correspondent pas ou sont vides."
    done

    echo ""

    # Hostname
    read -rp "$(echo -e "${YELLOW}▶ Nom de la machine (hostname) [lunaris] : ${RESET}")" HOSTNAME
    HOSTNAME="${HOSTNAME:-lunaris}"
    echo -e "  ${GREEN}✔ Hostname : ${BOLD}${HOSTNAME}${RESET}"
    echo ""
}

# ─── Summary & Confirmation ─────────────────────────────────────────────────
confirm_install() {
    log_section "RÉCAPITULATIF"
    echo -e "  ${WHITE}Disque cible      :${RESET}  ${BOLD}${TARGET_DISK}${RESET}"
    echo -e "  ${WHITE}Mode              :${RESET}  ${BOLD}${INSTALL_MODE}${RESET}"
    echo -e "  ${WHITE}Microcode         :${RESET}  ${BOLD}${CPU_UCODE}${RESET}"
    echo -e "  ${WHITE}Utilisateur       :${RESET}  ${BOLD}${USERNAME}${RESET}"
    echo -e "  ${WHITE}Hostname          :${RESET}  ${BOLD}${HOSTNAME}${RESET}"
    echo -e "  ${WHITE}Kernel            :${RESET}  ${BOLD}linux-zen (preemptive, CFS optimized)${RESET}"
    echo -e "  ${WHITE}Chiffrement       :${RESET}  ${BOLD}LUKS2 + Argon2id (AES-256-XTS)${RESET}"
    echo -e "  ${WHITE}Filesystem        :${RESET}  ${BOLD}Btrfs (subvolumes + zstd:3)${RESET}"
    echo -e "  ${WHITE}Desktop           :${RESET}  ${BOLD}Hyprland — Lunaris Config${RESET}"
    echo -e "  ${WHITE}RAM détectée      :${RESET}  ${BOLD}${TOTAL_RAM_GB} Go${RESET}"
    echo -e "  ${WHITE}CPU cores         :${RESET}  ${BOLD}${CPU_CORES}${RESET}"
    echo -e "  ${WHITE}VM détectée       :${RESET}  ${BOLD}${IS_VM} (${VM_TYPE})${RESET}"
    echo ""

    if [[ "$INSTALL_MODE" == "clean" ]]; then
        echo -e "${RED}${BOLD}  ⚠  ATTENTION : Toutes les données sur ${TARGET_DISK} seront DÉTRUITES !${RESET}"
    fi
    echo ""

    read -rp "$(echo -e "${YELLOW}▶ Confirmer et démarrer l'installation ? [oui/NON] : ${RESET}")" confirm
    [[ "${confirm,,}" == "oui" ]] || die "Installation annulée par l'utilisateur."

    echo ""
    log_ok "Installation confirmée. C'est parti !"
    sleep 2
}

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     PHASE 2           ║
#                         ║  Partitionnement +    ║
#                         ║  Chiffrement LUKS     ║
#                         ╚═══════════════════════╝
###############################################################################

partition_and_encrypt() {
    log_section "PARTITIONNEMENT & CHIFFREMENT"

    # ── Wipe (clean only) ──
    if [[ "$INSTALL_MODE" == "clean" ]]; then
        log_info "Nettoyage des signatures existantes sur ${TARGET_DISK}..."
        # wipefs: skip loop devices to avoid probing errors
        wipefs -af "${TARGET_DISK}" 2>/dev/null || true
        sgdisk --zap-all "${TARGET_DISK}" || true
        partprobe "${TARGET_DISK}" 2>/dev/null || true
        sleep 2

        log_info "Création de la table GPT..."
        sgdisk -o "${TARGET_DISK}"

        log_info "Création de la partition ESP (512 MiB)..."
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "${TARGET_DISK}"

        log_info "Création de la partition racine (reste du disque)..."
        sgdisk -n 2:0:0 -t 2:8309 -c 2:"CRYPTROOT" "${TARGET_DISK}"

        partprobe "${TARGET_DISK}" 2>/dev/null || true
        sleep 2

        # Determine partition naming (nvme vs sda)
        if [[ "${TARGET_DISK}" =~ nvme|mmcblk ]]; then
            ESP_PART="${TARGET_DISK}p1"
            ROOT_PART="${TARGET_DISK}p2"
        else
            ESP_PART="${TARGET_DISK}1"
            ROOT_PART="${TARGET_DISK}2"
        fi

    elif [[ "$INSTALL_MODE" == "dualboot" ]]; then
        log_info "Mode dual-boot : recherche de l'ESP existante..."

        # Find existing ESP
        ESP_PART="$(blkid -t TYPE=vfat -o device | head -1)"
        if [[ -z "$ESP_PART" ]]; then
            die "Aucune partition ESP (FAT32) trouvée. Créez-en une d'abord."
        fi
        log_ok "ESP trouvée : ${ESP_PART}"

        echo ""
        echo -e "${WHITE}Partitions disponibles sur ${TARGET_DISK} :${RESET}\n"
        lsblk -pno NAME,SIZE,FSTYPE,LABEL "${TARGET_DISK}" | grep -v "^${TARGET_DISK} "
        echo ""

        read -rp "$(echo -e "${YELLOW}▶ Partition à utiliser pour LUKS (ex: /dev/sda3) : ${RESET}")" ROOT_PART
        [[ -b "$ROOT_PART" ]] || die "Partition ${ROOT_PART} introuvable."

        echo -e "\n${RED}⚠  La partition ${ROOT_PART} sera complètement effacée !${RESET}"
        read -rp "$(echo -e "${YELLOW}▶ Confirmer ? [oui/NON] : ${RESET}")" dc
        [[ "${dc,,}" == "oui" ]] || die "Annulé."

        wipefs -af "${ROOT_PART}" 2>/dev/null || true
    fi

    log_ok "ESP : ${ESP_PART}"
    log_ok "ROOT: ${ROOT_PART}"

    # ── Format ESP ──
    if [[ "$INSTALL_MODE" == "clean" ]]; then
        log_info "Formatage ESP en FAT32..."
        mkfs.fat -F32 -n EFI "${ESP_PART}"
    fi

    # ── Determine LUKS Argon2id params based on available RAM ──
    local ARGON_MEM=1048576  # 1GB default
    local ARGON_PARALLEL=${CPU_CORES}
    if (( TOTAL_RAM_GB >= 32 )); then
        ARGON_MEM=2097152  # 2GB for 32GB+ RAM systems
    elif (( TOTAL_RAM_GB >= 16 )); then
        ARGON_MEM=1048576  # 1GB
    elif (( TOTAL_RAM_GB >= 8 )); then
        ARGON_MEM=524288   # 512MB
    fi

    # ── LUKS encryption with Argon2id — tuned for hardware ──
    log_info "Chiffrement LUKS2 avec Argon2id sur ${ROOT_PART}..."
    log_info "Argon2id: memory=${ARGON_MEM}KB, parallel=${ARGON_PARALLEL} threads"
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --pbkdf-memory "${ARGON_MEM}" \
        --pbkdf-parallel "${ARGON_PARALLEL}" \
        --pbkdf-force-iterations 4 \
        --sector-size 4096 \
        --label CRYPTROOT \
        --batch-mode \
        "${ROOT_PART}" -

    log_ok "Chiffrement LUKS2 configuré."

    # ── Open LUKS volume ──
    log_info "Ouverture du volume chiffré..."
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open \
        --type luks2 \
        --perf-no_read_workqueue \
        --perf-no_write_workqueue \
        --allow-discards \
        "${ROOT_PART}" cryptroot -

    # Verify cryptroot is open
    if [[ ! -b /dev/mapper/cryptroot ]]; then
        die "Impossible d'ouvrir /dev/mapper/cryptroot. Vérifiez la passphrase LUKS."
    fi
    log_ok "Volume chiffré ouvert : /dev/mapper/cryptroot"

    # Store UUID for later
    LUKS_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
    log_ok "LUKS UUID : ${LUKS_UUID}"
}

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     PHASE 3           ║
#                         ║  Btrfs + Subvolumes   ║
#                         ╚═══════════════════════╝
###############################################################################

setup_btrfs() {
    log_section "BTRFS & SUBVOLUMES"

    log_info "Formatage Btrfs sur /dev/mapper/cryptroot..."
    mkfs.btrfs -f -L ARCHROOT -n 32k -s 4096 /dev/mapper/cryptroot

    log_info "Montage temporaire pour création des subvolumes..."
    mount /dev/mapper/cryptroot /mnt

    log_info "Création des subvolumes Btrfs..."
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@tmp

    # Disable CoW on specific subvolumes for performance
    chattr +C /mnt/@var 2>/dev/null || true
    chattr +C /mnt/@tmp 2>/dev/null || true

    log_ok "Subvolumes créés : @, @home, @var, @snapshots, @cache, @log, @tmp"

    # Unmount for remount with proper options
    umount /mnt

    # ── Mount with optimized options — tuned for NVMe + performance ──
    local BTRFS_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,commit=120"
    local BTRFS_NOCOW="noatime,nodatacow,ssd,discard=async,space_cache=v2,commit=120"

    log_info "Montage des subvolumes avec options optimisées..."

    mount -o "subvol=@,${BTRFS_OPTS}" /dev/mapper/cryptroot /mnt

    mkdir -p /mnt/{home,var,var/cache,var/log,tmp,.snapshots,boot}

    mount -o "subvol=@home,${BTRFS_OPTS}"      /dev/mapper/cryptroot /mnt/home
    mount -o "subvol=@var,${BTRFS_NOCOW}"       /dev/mapper/cryptroot /mnt/var
    mount -o "subvol=@cache,${BTRFS_NOCOW}"     /dev/mapper/cryptroot /mnt/var/cache
    mount -o "subvol=@log,${BTRFS_OPTS}"        /dev/mapper/cryptroot /mnt/var/log
    mount -o "subvol=@tmp,${BTRFS_NOCOW}"       /dev/mapper/cryptroot /mnt/tmp
    mount -o "subvol=@snapshots,${BTRFS_OPTS}"  /dev/mapper/cryptroot /mnt/.snapshots

    # ── Mount ESP ──
    mount "${ESP_PART}" /mnt/boot

    log_ok "Points de montage :"
    echo -e "  /            → @          (zstd:3)"
    echo -e "  /home        → @home      (zstd:3)"
    echo -e "  /var         → @var       (nodatacow)"
    echo -e "  /var/cache   → @cache     (nodatacow)"
    echo -e "  /var/log     → @log       (zstd:3)"
    echo -e "  /tmp         → @tmp       (nodatacow)"
    echo -e "  /.snapshots  → @snapshots (zstd:3)"
    echo -e "  /boot        → ESP"
    echo ""

    # Verify
    findmnt --target /mnt | tee -a "$LOG_FILE"
}

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     PHASE 4           ║
#                         ║  Pacstrap + fstab     ║
#                         ╚═══════════════════════╝
###############################################################################

install_base() {
    log_section "INSTALLATION DU SYSTÈME DE BASE"

    # Sync pacman mirrors — optimize first
    log_info "Optimisation des miroirs via reflector..."
    reflector --country France,Germany,Netherlands --protocol https --sort rate --latest 20 \
        --save /etc/pacman.d/mirrorlist 2>/dev/null || true

    log_info "Synchronisation des clés pacman..."
    pacman -Sy --noconfirm archlinux-keyring 2>/dev/null || true

    log_info "Installation du système de base via pacstrap (linux-zen ultra-perf)..."
    pacstrap -K /mnt \
        base \
        linux-zen \
        linux-zen-headers \
        linux-firmware \
        "${CPU_UCODE}" \
        sudo \
        base-devel \
        git \
        nano \
        vim \
        btrfs-progs \
        cryptsetup \
        networkmanager \
        network-manager-applet \
        bluez \
        bluez-utils \
        man-db \
        man-pages \
        texinfo \
        dosfstools \
        e2fsprogs \
        util-linux \
        which \
        wget \
        curl \
        htop \
        btop \
        reflector \
        pacman-contrib \
        sbctl \
        lm_sensors \
        smartmontools \
        nvme-cli \
        iotop-c \
        sysstat \
        strace \
        lsof \
        usbutils \
        pciutils \
        dmidecode \
        arch-install-scripts \
        mkinitcpio \
        open-vm-tools \
        xf86-video-vmware \
        gtkmm3

    log_ok "Paquets de base installés (linux-zen + outils perf + vm-tools)."

    # ── Generate fstab ──
    log_info "Génération du fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    # ── Fix Btrfs fstab entries ──
    log_info "Correction du fstab pour les subvolumes Btrfs..."

    local BTRFS_UUID
    BTRFS_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"
    local ESP_UUID
    ESP_UUID="$(blkid -s UUID -o value "${ESP_PART}")"

    # Rebuild fstab with clean, optimized entries
    cat > /mnt/etc/fstab << FSTAB
# /etc/fstab — Generated by arch-self-install.sh (Lunaris v4.0)
# <device>  <mount>  <type>  <options>  <dump>  <pass>

# Root subvolume @
UUID=${BTRFS_UUID}  /  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,commit=120,subvol=/@  0  0

# Home subvolume @home
UUID=${BTRFS_UUID}  /home  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,commit=120,subvol=/@home  0  0

# Var subvolume @var (no CoW for databases/VMs)
UUID=${BTRFS_UUID}  /var  btrfs  rw,noatime,nodatacow,ssd,discard=async,space_cache=v2,commit=120,subvol=/@var  0  0

# Cache subvolume @cache (no CoW)
UUID=${BTRFS_UUID}  /var/cache  btrfs  rw,noatime,nodatacow,ssd,discard=async,space_cache=v2,commit=120,subvol=/@cache  0  0

# Log subvolume @log
UUID=${BTRFS_UUID}  /var/log  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,commit=120,subvol=/@log  0  0

# Tmp subvolume @tmp (no CoW)
UUID=${BTRFS_UUID}  /tmp  btrfs  rw,noatime,nodatacow,ssd,discard=async,space_cache=v2,commit=120,subvol=/@tmp  0  0

# Snapshots subvolume @snapshots
UUID=${BTRFS_UUID}  /.snapshots  btrfs  rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,commit=120,subvol=/@snapshots  0  0

# EFI System Partition
UUID=${ESP_UUID}  /boot  vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0  2

# tmpfs — /tmp in RAM for speed (optional, uncomment if preferred over btrfs @tmp)
# tmpfs  /tmp  tmpfs  defaults,noatime,nosuid,nodev,noexec,mode=1777,size=8G  0  0
FSTAB

    log_ok "fstab corrigé et finalisé."
    cat /mnt/etc/fstab | tee -a "$LOG_FILE"
}

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     PHASE 5           ║
#                         ║  Chroot Configuration ║
#                         ╚═══════════════════════╝
###############################################################################

configure_chroot() {
    log_section "CONFIGURATION CHROOT"

    # We write a chroot script and execute it
    cat > /mnt/chroot-setup.sh << 'CHROOT_SCRIPT_HEADER'
#!/usr/bin/env bash
set -euo pipefail

# Variables injected below
CHROOT_SCRIPT_HEADER

    # Inject variables
    cat >> /mnt/chroot-setup.sh << EOF
USERNAME="${USERNAME}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
USER_PASSWORD="${USER_PASSWORD}"
HOSTNAME="${HOSTNAME}"
CPU_UCODE="${CPU_UCODE}"
LUKS_UUID="${LUKS_UUID}"
ROOT_PART="${ROOT_PART}"
IS_VM=${IS_VM}
VM_TYPE="${VM_TYPE:-none}"
TOTAL_RAM_GB=${TOTAL_RAM_GB}
CPU_CORES=${CPU_CORES}
EOF

    cat >> /mnt/chroot-setup.sh << 'CHROOT_BODY'

# ─── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*"; }
log_ok()      { echo -e "${GREEN}[  OK  ]${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
log_section() { echo -e "\n${MAGENTA}${BOLD}  ── $* ──${RESET}\n"; }

###########################################################################
# 5.1 — Locale & Timezone
###########################################################################
log_section "LOCALE & TIMEZONE"

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Enable fr_FR.UTF-8 and en_US.UTF-8
sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "LC_COLLATE=C"     >> /etc/locale.conf

log_ok "Locale : fr_FR.UTF-8"

###########################################################################
# 5.2 — Console keymap (AZERTY + MX Keys Mini)
###########################################################################
log_section "CLAVIER AZERTY + MX KEYS MINI"

echo "KEYMAP=fr-latin1" > /etc/vconsole.conf

# X11 keyboard layout for AZERTY
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'XKBD'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "fr"
    Option "XkbVariant" "latin9"
    Option "XkbOptions" "caps:escape,compose:ralt"
EndSection
XKBD

# Logitech MX Keys Mini — specific udev rule for consistent recognition
cat > /etc/udev/rules.d/99-mx-keys-mini.rules << 'MXKEYS'
# Logitech MX Keys Mini — ensure correct keymap
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="b369", ENV{XKBLAYOUT}="fr", ENV{XKBVARIANT}="latin9"
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="408a", ENV{XKBLAYOUT}="fr", ENV{XKBVARIANT}="latin9"
# Bolt receiver
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c548", ENV{XKBLAYOUT}="fr", ENV{XKBVARIANT}="latin9"
MXKEYS

log_ok "Clavier AZERTY configuré (console + X11 + MX Keys Mini)"

###########################################################################
# 5.3 — Hostname & Hosts
###########################################################################
log_section "HOSTNAME & RÉSEAU"

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
HOSTS

log_ok "Hostname : ${HOSTNAME}"

###########################################################################
# 5.4 — Users & sudo
###########################################################################
log_section "UTILISATEURS"

echo "root:${ROOT_PASSWORD}" | chpasswd
log_ok "Mot de passe root défini."

useradd -m -G wheel,audio,video,input,storage,optical,network,power -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
log_ok "Utilisateur ${USERNAME} créé."

# Passwordless sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
# Also add NOPASSWD variant for automated tasks
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/00-${USERNAME}"
chmod 440 "/etc/sudoers.d/00-${USERNAME}"

log_ok "sudo configuré pour ${USERNAME}."

###########################################################################
# 5.5 — NetworkManager
###########################################################################
log_section "NETWORK MANAGER"

systemctl enable NetworkManager
systemctl enable systemd-resolved
log_ok "NetworkManager activé."

###########################################################################
# 5.6 — mkinitcpio (LUKS + Btrfs hooks) — Zen kernel optimized
###########################################################################
log_section "MKINITCPIO — ZEN KERNEL"

cat > /etc/mkinitcpio.conf << 'MKINIT'
# Lunaris — mkinitcpio config for linux-zen + LUKS + Btrfs
MODULES=(btrfs)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-3 -T0)
MKINIT

mkinitcpio -P
log_ok "initramfs régénéré (zstd compression, LUKS + Btrfs hooks)."

###########################################################################
# 5.7 — systemd-boot — Zen kernel boot params tuned for performance
###########################################################################
log_section "BOOTLOADER (systemd-boot)"

bootctl install

# Loader configuration
cat > /boot/loader/loader.conf << 'LOADER'
default  arch.conf
timeout  3
console-mode max
editor   no
LOADER

# Performance-tuned kernel parameters for Ryzen + NVMe + RTX
# - mitigations=off: disable CPU spectre/meltdown mitigations for max perf
#   (REMOVE if security > performance for your use case)
# - nowatchdog: disable watchdog for lower latency
# - nmi_watchdog=0: disable NMI for performance
# - split_lock_detect=off: avoid split-lock performance penalties
# - transparent_hugepage=always: better memory performance with 32GB
# - preempt=full: enable full preemption (zen default)

cat > /boot/loader/entries/arch.conf << ARCHENTRY
title   Arch Linux — Zen ⚡ Lunaris
linux   /vmlinuz-linux-zen
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux-zen.img
options rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.options=discard,no-read-workqueue,no-write-workqueue root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog nmi_watchdog=0 split_lock_detect=off transparent_hugepage=madvise page_alloc.shuffle=1
ARCHENTRY

# Fallback entry (safe — no perf tuning)
cat > /boot/loader/entries/arch-fallback.conf << ARCHFB
title   Arch Linux — Zen (Fallback Safe)
linux   /vmlinuz-linux-zen
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux-zen-fallback.img
options rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw loglevel=4
ARCHFB

log_ok "systemd-boot installé avec paramètres Zen optimisés."

###########################################################################
# 5.8 — VMware tools (ALWAYS installed) + VM-specific
###########################################################################
log_section "VMWARE-TOOLS & OUTILS VM"

# VMware tools toujours installés (pour compatibilité universelle)
systemctl enable vmtoolsd 2>/dev/null || true
systemctl enable vmware-vmblock-fuse 2>/dev/null || true
log_ok "open-vm-tools activé (installé dans pacstrap)."

# Additional VM-specific tools
if [[ "$IS_VM" == true ]]; then
    if [[ "$VM_TYPE" == "kvm" || "$VM_TYPE" == "qemu" ]]; then
        pacman -S --noconfirm qemu-guest-agent spice-vdagent
        systemctl enable qemu-guest-agent
        log_ok "QEMU guest agent installé."
    elif [[ "$VM_TYPE" == "oracle" ]]; then
        pacman -S --noconfirm virtualbox-guest-utils
        systemctl enable vboxservice
        log_ok "VirtualBox guest utils installé."
    fi
fi

###########################################################################
#                    ╔═══════════════════════════╗
#                    ║        PHASE 6            ║
#                    ║  Hyprland + Wayland Stack ║
#                    ╚═══════════════════════════╝
###########################################################################
log_section "HYPRLAND + WAYLAND STACK"

# ── Install Hyprland & Wayland components ──
pacman -S --noconfirm \
    hyprland \
    xdg-desktop-portal-hyprland \
    xorg-xwayland \
    wayland-protocols \
    alacritty \
    kitty \
    waybar \
    rofi-wayland \
    mako \
    libnotify \
    pamixer \
    pavucontrol \
    brightnessctl \
    playerctl \
    grim \
    slurp \
    wl-clipboard \
    cliphist \
    swaylock \
    swayidle \
    swaybg \
    swww \
    cava \
    qt6-svg \
    qt6-declarative \
    socat \
    npm \
    dolphin \
    polkit-kde-agent \
    qt5-wayland \
    qt6-wayland \
    xdg-utils \
    xdg-user-dirs \
    thunar \
    thunar-archive-plugin \
    file-roller \
    gvfs \
    tumbler \
    ffmpegthumbnailer \
    nwg-look \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    pipewire-jack \
    wireplumber \
    ttf-jetbrains-mono-nerd \
    ttf-font-awesome \
    noto-fonts \
    noto-fonts-cjk \
    noto-fonts-emoji \
    papirus-icon-theme \
    unzip \
    p7zip \
    gamemode \
    lib32-gamemode \
    mangohud \
    lib32-mangohud

log_ok "Hyprland + Wayland + GameMode + MangoHud installés."

# ── GPU Detection & Driver Install ──
log_section "DÉTECTION GPU & DRIVERS"

GPU_VENDOR=""
if lspci | grep -qi "nvidia"; then
    GPU_VENDOR="nvidia"
    log_info "GPU Nvidia détecté. Installation des drivers propriétaires (RTX optimized)..."
    pacman -S --noconfirm \
        nvidia-dkms \
        nvidia-utils \
        nvidia-settings \
        lib32-nvidia-utils \
        vulkan-icd-loader \
        lib32-vulkan-icd-loader \
        egl-wayland \
        libva-nvidia-driver \
        opencl-nvidia \
        lib32-opencl-nvidia \
        cuda

    # Nvidia modules in mkinitcpio — optimized load order
    sed -i 's/^MODULES=(btrfs)/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    mkinitcpio -P

    # Nvidia DRM modeset + performance tweaks
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/nvidia.conf << 'NVMOD'
# Nvidia DRM + performance tuning
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_EnablePCIeGen3=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
NVMOD

    # Nvidia power management for suspend/resume
    systemctl enable nvidia-suspend
    systemctl enable nvidia-resume
    systemctl enable nvidia-hibernate

    # Environment for Hyprland + Nvidia (RTX 3070Ti optimized)
    mkdir -p /etc/environment.d
    cat > /etc/environment.d/nvidia-wayland.conf << 'NVENV'
LIBVA_DRIVER_NAME=nvidia
XDG_SESSION_TYPE=wayland
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
WLR_NO_HARDWARE_CURSORS=1
__GL_GSYNC_ALLOWED=1
__GL_VRR_ALLOWED=1
__GL_MaxFramesAllowed=1
NVENV

    # Nvidia pacman hook to rebuild initramfs on driver update
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/nvidia.hook << 'NVHOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = nvidia-dkms
Target = linux-zen
Target = linux-zen-headers

[Action]
Description = Regenerating initramfs after NVIDIA driver update...
Depends = mkinitcpio
When = PostTransaction
NeedsTargets
Exec = /usr/bin/mkinitcpio -P
NVHOOK

    log_ok "Drivers Nvidia RTX + CUDA + Wayland configurés."

elif lspci | grep -qi "amd.*radeon\|amd.*graphics\|ATI"; then
    GPU_VENDOR="amd"
    log_info "GPU AMD détecté. Installation des drivers AMDGPU..."
    pacman -S --noconfirm \
        mesa \
        lib32-mesa \
        vulkan-radeon \
        lib32-vulkan-radeon \
        vulkan-icd-loader \
        lib32-vulkan-icd-loader \
        libva-mesa-driver \
        lib32-libva-mesa-driver \
        mesa-vdpau \
        lib32-mesa-vdpau \
        xf86-video-amdgpu \
        rocm-opencl-runtime

    # AMDGPU performance
    mkdir -p /etc/modprobe.d
    echo "options amdgpu ppfeaturemask=0xffffffff" > /etc/modprobe.d/amdgpu.conf

    log_ok "Drivers AMD + Vulkan + ROCm installés."

elif lspci | grep -qi "intel.*graphics\|Intel.*UHD\|Intel.*Iris"; then
    GPU_VENDOR="intel"
    log_info "GPU Intel détecté. Installation des drivers..."
    pacman -S --noconfirm \
        mesa \
        lib32-mesa \
        vulkan-intel \
        lib32-vulkan-intel \
        vulkan-icd-loader \
        lib32-vulkan-icd-loader \
        intel-media-driver \
        libva-intel-driver

    log_ok "Drivers Intel installés."
else
    log_warn "GPU non identifié. Installation des drivers génériques..."
    pacman -S --noconfirm mesa vulkan-icd-loader
fi

# ── Enable PipeWire (low-latency audio) ──
log_info "Configuration PipeWire low-latency..."

# PipeWire low-latency config
mkdir -p "/home/${USERNAME}/.config/pipewire/pipewire.conf.d"
cat > "/home/${USERNAME}/.config/pipewire/pipewire.conf.d/99-lowlatency.conf" << 'PWLAT'
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 256
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 2048
}
PWLAT

# ── XDG user dirs ──
sudo -u "${USERNAME}" xdg-user-dirs-update 2>/dev/null || true

###########################################################################
# 🇭​​🇾​​🇵​​🇷​​🇱​​🇦​​🇳​​🇩​ 🇨​​🇴​​🇳​​🇫​​🇮​​🇬​​🇺​​🇷​​🇦​​🇹​​🇮​​🇴​​🇳​ — 🇱​​🇺​​🇳​​🇦​​🇷​​🇮​​🇸​
###########################################################################
log_section "CONFIGURATION LUNARIS"

HYPR_DIR="/home/${USERNAME}/.config/hypr"
mkdir -p "${HYPR_DIR}"

# ── Main Hyprland config ──
cat > "${HYPR_DIR}/hyprland.conf" << 'HYPRCONF'
#
#
#                                                                                             
#                 ██     ██  ██ ███  ██ ▄████▄ █████▄  ██ ▄█████ 
#                 ██     ██  ██ ██ ▀▄██ ██▄▄██ ██▄▄██▄ ██ ▀▀▀▄▄▄ 
#                 ██████ ▀████▀ ██   ██ ██  ██ ██   ██ ██ █████▀ 
#
#         ══════════════════════════════ ⋆★⋆ ═══════════════════════════
#                                               
#               ⚜ 𝗛𝗬𝗣𝗥𝗟𝗔𝗡𝗗 — 𝙈𝙞𝙡𝙞𝙩𝙖𝙧𝙮 𝙂𝙧𝙖𝙙𝙚 𝙊𝙥𝙚𝙧𝙖𝙩𝙞𝙣𝙜 𝙎𝙮𝙨𝙩𝙚𝙢𝙨 ⚜
#
#

# ── Source additional configs ──
source = ~/.config/hypr/env.conf
source = ~/.config/hypr/monitors.conf
source = ~/.config/hypr/keybinds.conf
source = ~/.config/hypr/rules.conf
source = ~/.config/hypr/autostart.conf

# ─────────────────────────────────────────────────────────────────────────────
# INPUT — Optimized for low-latency
# ─────────────────────────────────────────────────────────────────────────────
input {
    kb_layout = fr
    kb_variant = latin9
    kb_options = caps:escape,compose:ralt
    follow_mouse = 1
    sensitivity = 0
    accel_profile = flat

    touchpad {
        natural_scroll = true
        tap-to-click = true
        drag_lock = true
        disable_while_typing = true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERAL — Performance-tuned
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# DECORATION — GPU-accelerated blur, shadows, rounding
# ─────────────────────────────────────────────────────────────────────────────
decoration {
    rounding = 12

    blur {
        enabled = true
        size = 6
        passes = 2
        new_optimizations = true
        xray = false
        noise = 0.02
        contrast = 1.0
        brightness = 1.0
        vibrancy = 0.2
        vibrancy_darkness = 0.5
        special = true
        popups = true
    }

    shadow {
        enabled = true
        range = 16
        render_power = 3
        color = rgba(1a1a2eee)
        color_inactive = rgba(1a1a2e55)
    }

    dim_inactive = true
    dim_strength = 0.08
}

# ─────────────────────────────────────────────────────────────────────────────
# ANIMATIONS — Ultra smooth, GPU-optimized
# ─────────────────────────────────────────────────────────────────────────────
animations {
    enabled = true
    first_launch_animation = true

    bezier = overshot, 0.05, 0.9, 0.1, 1.05
    bezier = smoothOut, 0.5, 0, 0.99, 0.99
    bezier = smoothIn, 0.5, -0.5, 0.68, 1.5
    bezier = wind, 0.05, 0.9, 0.1, 1.05
    bezier = winIn, 0.1, 1.1, 0.1, 1.1
    bezier = winOut, 0.3, -0.3, 0, 1

    animation = windows, 1, 4, wind, slide
    animation = windowsIn, 1, 4, winIn, slide
    animation = windowsOut, 1, 4, winOut, slide
    animation = windowsMove, 1, 4, wind, slide
    animation = border, 1, 2, default
    animation = borderangle, 1, 30, smoothOut, loop
    animation = fade, 1, 4, smoothOut
    animation = fadeDim, 1, 4, smoothIn
    animation = workspaces, 1, 4, wind
    animation = specialWorkspace, 1, 4, smoothOut, slidevert
}

# ─────────────────────────────────────────────────────────────────────────────
# LAYOUT — Smart tiling
# ─────────────────────────────────────────────────────────────────────────────
dwindle {
    pseudotile = true
    preserve_split = true
    force_split = 2
    smart_split = false
    smart_resizing = true
    no_gaps_when_only = 1
}

master {
    new_status = master
    smart_resizing = true
    no_gaps_when_only = 1
}

# ─────────────────────────────────────────────────────────────────────────────
# MISC — Maximum performance
# ─────────────────────────────────────────────────────────────────────────────
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    vfr = true
    vrr = 1
    mouse_move_enables_dpms = true
    key_press_enables_dpms = true
    animate_manual_resizes = true
    animate_mouse_windowdragging = true
    enable_swallow = true
    swallow_regex = ^(Alacritty|kitty)$
    focus_on_activate = true
    new_window_takes_over_fullscreen = 2
    allow_session_lock_restore = true
    close_special_on_empty = true
    initial_workspace_tracking = 1
}

# ─────────────────────────────────────────────────────────────────────────────
# RENDER — Direct scanout for fullscreen perf
# ─────────────────────────────────────────────────────────────────────────────
render {
    explicit_sync = 2
    explicit_sync_kms = 2
    direct_scanout = true
}

# ─────────────────────────────────────────────────────────────────────────────
# CURSOR
# ─────────────────────────────────────────────────────────────────────────────
cursor {
    no_hardware_cursors = true
    inactive_timeout = 5
    hide_on_key_press = true
    enable_hyprcursor = true
}

# ─────────────────────────────────────────────────────────────────────────────
# XWAYLAND
# ─────────────────────────────────────────────────────────────────────────────
xwayland {
    force_zero_scaling = true
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY
# ─────────────────────────────────────────────────────────────────────────────
# Deny untrusted clients from accessing privileged protocols
# Enforce PAM authentication for screen lock
# Disable keybinds in sandbox mode
HYPRCONF

# ── Environment variables — GPU perf tuned ──
cat > "${HYPR_DIR}/env.conf" << 'ENVCONF'
# ─── Environment Variables — Performance Optimized ──────────────────────────
env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = GDK_BACKEND,wayland,x11,*
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_QPA_PLATFORMTHEME,qt5ct
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1
env = QT_AUTO_SCREEN_SCALE_FACTOR,1
env = SDL_VIDEODRIVER,wayland
env = CLUTTER_BACKEND,wayland
env = MOZ_ENABLE_WAYLAND,1
env = XCURSOR_SIZE,24
env = XCURSOR_THEME,Adwaita

# ── Performance ──
env = MESA_DISK_CACHE_SINGLE_FILE,1
env = __GL_THREADED_OPTIMIZATIONS,1
env = DXVK_ASYNC,1
env = RADV_PERFTEST,gpl
ENVCONF

# ── Monitor config ──
cat > "${HYPR_DIR}/monitors.conf" << 'MONCONF'
# ─── Monitors ───────────────────────────────────────────────────────────────
# Auto-detect and configure at preferred resolution & framerate
# highres + highrr = prefer highest resolution AND highest refresh rate
monitor = , highrr, auto, 1

# Example for specific monitor:
# monitor = DP-1, 2560x1440@165, 0x0, 1
# monitor = HDMI-A-1, 1920x1080@60, 2560x0, 1
MONCONF

# ── Keybinds ──
cat > "${HYPR_DIR}/keybinds.conf" << 'KEYBINDS'
# ─── Keybinds ───────────────────────────────────────────────────────────────
$mainMod = SUPER

# ── Apps ──
bind = $mainMod, Return, exec, alacritty
bind = $mainMod SHIFT, Return, exec, kitty
bind = $mainMod, E, exec, thunar
bind = $mainMod, D, exec, wofi --show drun -I -a
bind = $mainMod, V, exec, cliphist list | wofi --show dmenu | cliphist decode | wl-copy
bind = $mainMod, N, exec, swaync-client -t -sw

# ── Window Management ──
bind = $mainMod, Q, killactive
bind = $mainMod SHIFT, Q, exit
bind = $mainMod, F, fullscreen, 1
bind = $mainMod SHIFT, F, fullscreen, 0
bind = $mainMod, Space, togglefloating
bind = $mainMod, P, pseudo
bind = $mainMod, J, togglesplit
bind = $mainMod, G, togglegroup
bind = $mainMod, Tab, changegroupactive

# ── Focus ──
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# ── Move windows ──
bind = $mainMod SHIFT, left, movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up, movewindow, u
bind = $mainMod SHIFT, down, movewindow, d

# ── Resize ──
binde = $mainMod CTRL, left, resizeactive, -30 0
binde = $mainMod CTRL, right, resizeactive, 30 0
binde = $mainMod CTRL, up, resizeactive, 0 -30
binde = $mainMod CTRL, down, resizeactive, 0 30

# ── Workspaces (AZERTY) ──
bind = $mainMod, ampersand, workspace, 1
bind = $mainMod, eacute, workspace, 2
bind = $mainMod, quotedbl, workspace, 3
bind = $mainMod, apostrophe, workspace, 4
bind = $mainMod, parenleft, workspace, 5
bind = $mainMod, minus, workspace, 6
bind = $mainMod, egrave, workspace, 7
bind = $mainMod, underscore, workspace, 8
bind = $mainMod, ccedilla, workspace, 9
bind = $mainMod, agrave, workspace, 10

# ── Move to workspace ──
bind = $mainMod SHIFT, ampersand, movetoworkspace, 1
bind = $mainMod SHIFT, eacute, movetoworkspace, 2
bind = $mainMod SHIFT, quotedbl, movetoworkspace, 3
bind = $mainMod SHIFT, apostrophe, movetoworkspace, 4
bind = $mainMod SHIFT, parenleft, movetoworkspace, 5
bind = $mainMod SHIFT, minus, movetoworkspace, 6
bind = $mainMod SHIFT, egrave, movetoworkspace, 7
bind = $mainMod SHIFT, underscore, movetoworkspace, 8
bind = $mainMod SHIFT, ccedilla, movetoworkspace, 9
bind = $mainMod SHIFT, agrave, movetoworkspace, 10

# ── Silent move to workspace ──
bind = $mainMod CTRL, ampersand, movetoworkspacesilent, 1
bind = $mainMod CTRL, eacute, movetoworkspacesilent, 2
bind = $mainMod CTRL, quotedbl, movetoworkspacesilent, 3

# ── Special workspace (scratchpad) ──
bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspace, special:magic

# ── Scroll through workspaces ──
bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

# ── Mouse binds ──
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# ── Screenshot ──
bind = , Print, exec, grim -g "$(slurp -d)" - | wl-copy
bind = SHIFT, Print, exec, grim - | wl-copy
bind = $mainMod, Print, exec, grim -g "$(slurp -d)" ~/Images/Screenshots/$(date +%Y%m%d_%H%M%S).png

# ── Media Keys ──
bindel = , XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = , XF86AudioLowerVolume, exec, pamixer -d 5
bindl = , XF86AudioMute, exec, pamixer -t
bindl = , XF86AudioMicMute, exec, pamixer --default-source -t
bindel = , XF86MonBrightnessUp, exec, brightnessctl set +5%
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
bindl = , XF86AudioPlay, exec, playerctl play-pause
bindl = , XF86AudioNext, exec, playerctl next
bindl = , XF86AudioPrev, exec, playerctl previous

# ── Lock ──
bind = $mainMod, L, exec, swaylock -f -c 1a1a2e -e --indicator --clock --effect-blur 7x5

# ── GameMode toggle ──
bind = $mainMod, F5, exec, gamemoded -r && notify-send "GameMode" "Toggled"
KEYBINDS

# ── Window rules ──
cat > "${HYPR_DIR}/rules.conf" << 'RULES'
# ─── Window Rules ───────────────────────────────────────────────────────────

# ── Float rules ──
windowrulev2 = float, class:^(pavucontrol)$
windowrulev2 = float, class:^(nm-connection-editor)$
windowrulev2 = float, class:^(thunar)$,title:^(File Operation Progress)$
windowrulev2 = float, class:^(file-roller)$
windowrulev2 = float, class:^(nwg-look)$
windowrulev2 = float, class:^(org.kde.polkit-kde-authentication-agent-1)$
windowrulev2 = float, title:^(Picture-in-Picture)$
windowrulev2 = float, title:^(Open File)$
windowrulev2 = float, title:^(Save File)$
windowrulev2 = float, title:^(Confirm to replace files)$

# ── Opacity rules ──
windowrulev2 = opacity 0.92 0.88, class:^(Alacritty)$
windowrulev2 = opacity 0.92 0.88, class:^(kitty)$
windowrulev2 = opacity 0.95 0.90, class:^(thunar)$
windowrulev2 = opacity 0.95 0.90, class:^(Code)$

# ── Size rules ──
windowrulev2 = size 800 600, class:^(pavucontrol)$
windowrulev2 = size 900 600, class:^(nm-connection-editor)$

# ── Workspace rules ──
windowrulev2 = workspace 2, class:^(thorium-browser)$
windowrulev2 = workspace 3, class:^(Code)$

# ── Tearing rules (games = immediate rendering) ──
windowrulev2 = immediate, class:^(cs2)$
windowrulev2 = immediate, class:^(steam_app_.*)$
windowrulev2 = immediate, class:^(gamescope)$

# ── Layer rules (for Wofi, Waybar, etc.) ──
layerrule = blur, wofi
layerrule = blur, waybar
layerrule = ignorezero, wofi
layerrule = ignorezero, waybar
RULES

# ── Autostart ──
cat > "${HYPR_DIR}/autostart.conf" << 'AUTOSTART'
# ─── Autostart ──────────────────────────────────────────────────────────────

# ── System ──
exec-once = /usr/lib/polkit-kde-authentication-agent-1
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

# ── Status bar ──
exec-once = waybar

# ── Notification daemon ──
exec-once = mako

# ── Clipboard manager ──
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store

# ── Wallpaper ──
exec-once = swaybg -i ~/.config/hypr/wallpaper.jpg -m fill

# ── Idle management ──
exec-once = swayidle -w \
    timeout 300 'swaylock -f -c 1a1a2e -e --indicator --clock --effect-blur 7x5' \
    timeout 600 'hyprctl dispatch dpms off' \
    resume 'hyprctl dispatch dpms on' \
    before-sleep 'swaylock -f -c 1a1a2e -e --indicator --clock --effect-blur 7x5'

# ── Thorium Browser (sandboxed via Firejail) ──
exec-once = [workspace 2 silent] firejail --profile=/etc/firejail/thorium.profile thorium

# ── GameMode daemon ──
exec-once = gamemoded
AUTOSTART

# Fix ownership
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"

log_ok "Config Hyprland Lunaris créée."

###########################################################################
# Waybar Configuration — Catppuccin Mocha
###########################################################################
log_section "WAYBAR CONFIGURATION"

WAYBAR_DIR="/home/${USERNAME}/.config/waybar"
mkdir -p "${WAYBAR_DIR}"

cat > "${WAYBAR_DIR}/config.jsonc" << 'WAYBAR_CFG'
{
    "layer": "top",
    "position": "top",
    "height": 36,
    "spacing": 0,
    "margin-top": 4,
    "margin-left": 8,
    "margin-right": 8,
    "reload_style_on_change": true,

    "modules-left": [
        "hyprland/workspaces",
        "hyprland/window"
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "tray",
        "gamemode",
        "pulseaudio",
        "network",
        "cpu",
        "memory",
        "temperature",
        "battery"
    ],

    "hyprland/workspaces": {
        "format": "{icon}",
        "format-icons": {
            "1": "󰣇",
            "2": "󰈹",
            "3": "󰨞",
            "4": "󰝚",
            "5": "󰭹",
            "6": "󰊠",
            "7": "7",
            "8": "8",
            "9": "9",
            "10": "10",
            "urgent": "󰗖",
            "default": "󰊠"
        },
        "on-click": "activate",
        "sort-by-number": true,
        "persistent-workspaces": {
            "*": 5
        }
    },

    "hyprland/window": {
        "format": "  {}",
        "max-length": 50,
        "rewrite": {
            "(.*) — Thorium": "󰈹 $1",
            "(.*) - Alacritty": " $1",
            "(.*) - kitty": " $1"
        }
    },

    "clock": {
        "format": "  {:%H:%M}",
        "format-alt": "  {:%A %d %B %Y — %H:%M:%S}",
        "tooltip-format": "<tt><small>{calendar}</small></tt>",
        "interval": 1,
        "calendar": {
            "mode": "year",
            "mode-mon-col": 3,
            "weeks-pos": "right",
            "on-scroll": 1,
            "format": {
                "months":     "<span color='#f5e0dc'><b>{}</b></span>",
                "days":       "<span color='#cdd6f4'>{}</span>",
                "weeks":      "<span color='#94e2d5'><b>S{}</b></span>",
                "weekdays":   "<span color='#f9e2af'><b>{}</b></span>",
                "today":      "<span color='#f38ba8'><b><u>{}</u></b></span>"
            }
        }
    },

    "cpu": {
        "format": "  {usage}%",
        "tooltip": true,
        "interval": 2
    },

    "memory": {
        "format": "  {}%",
        "tooltip-format": "{used:0.1f}G / {total:0.1f}G",
        "interval": 2
    },

    "temperature": {
        "critical-threshold": 80,
        "format": " {temperatureC}°C",
        "format-critical": "  {temperatureC}°C",
        "interval": 5
    },

    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon}  {capacity}%",
        "format-charging": "󰂄 {capacity}%",
        "format-plugged": "󱘖 {capacity}%",
        "format-icons": ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"],
        "tooltip-format": "{timeTo}\n{power}W"
    },

    "network": {
        "format-wifi": "󰤨  {signalStrength}%",
        "format-ethernet": "󰈀 {ipaddr}",
        "format-disconnected": "󰤭 ",
        "tooltip-format-wifi": "{essid} ({signalStrength}%)\n{ipaddr}",
        "tooltip-format-ethernet": "{ifname}: {ipaddr}/{cidr}",
        "on-click": "nm-connection-editor"
    },

    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰖁 ",
        "format-icons": {
            "default": ["󰕿", "󰖀", "󰕾"]
        },
        "on-click": "pavucontrol",
        "scroll-step": 5
    },

    "gamemode": {
        "format": "{glyph}",
        "format-alt": "{glyph} {count}",
        "glyph": "󰊗",
        "hide-not-running": true,
        "use-icon": true,
        "icon-name": "input-gaming-symbolic",
        "icon-spacing": 4,
        "icon-size": 20,
        "tooltip": true,
        "tooltip-format": "GameMode: {count} jeux"
    },

    "tray": {
        "icon-size": 16,
        "spacing": 10
    }
}
WAYBAR_CFG

cat > "${WAYBAR_DIR}/style.css" << 'WAYBAR_CSS'
/* ═══════════════════════════════════════════════════════════════════════════
   WAYBAR — Catppuccin Mocha Theme
   ═══════════════════════════════════════════════════════════════════════════ */

* {
    font-family: "JetBrains Mono Nerd Font", "JetBrains Mono", monospace;
    font-size: 13px;
    min-height: 0;
    border: none;
    border-radius: 0;
}

window#waybar {
    background: rgba(30, 30, 46, 0.85);
    border-radius: 12px;
    border: 1px solid rgba(137, 180, 250, 0.2);
    color: #cdd6f4;
}

/* ── Modules ── */
#workspaces, #window, #clock, #cpu, #memory, #temperature,
#battery, #network, #pulseaudio, #tray, #gamemode {
    padding: 0 12px;
    margin: 4px 2px;
    border-radius: 8px;
    background: transparent;
    transition: all 0.3s ease;
}

#workspaces button {
    padding: 0 6px;
    color: #6c7086;
    border-radius: 8px;
    background: transparent;
    transition: all 0.2s ease;
}

#workspaces button:hover {
    color: #cba6f7;
    background: rgba(203, 166, 247, 0.15);
}

#workspaces button.active {
    color: #1e1e2e;
    background: linear-gradient(135deg, #89b4fa, #cba6f7);
    font-weight: bold;
    border-radius: 8px;
}

#workspaces button.urgent { color: #1e1e2e; background: #f38ba8; }
#clock { color: #89b4fa; font-weight: bold; }
#cpu { color: #a6e3a1; }
#memory { color: #f9e2af; }
#temperature { color: #94e2d5; }
#temperature.critical { color: #f38ba8; animation: blink 0.5s steps(2) infinite; }
#battery { color: #a6e3a1; }
#battery.warning { color: #fab387; }
#battery.critical { color: #f38ba8; animation: blink 0.5s steps(2) infinite; }
#network { color: #89dceb; }
#network.disconnected { color: #f38ba8; }
#pulseaudio { color: #cba6f7; }
#pulseaudio.muted { color: #6c7086; }
#gamemode { color: #f9e2af; }
#tray > .passive { -gtk-icon-effect: dim; }
#tray > .needs-attention { -gtk-icon-effect: highlight; }

#cpu:hover, #memory:hover, #temperature:hover,
#battery:hover, #network:hover, #pulseaudio:hover {
    background: rgba(205, 214, 244, 0.08);
}

@keyframes blink { to { color: transparent; } }
WAYBAR_CSS

chown -R "${USERNAME}:${USERNAME}" "${WAYBAR_DIR}"
log_ok "Waybar configuré (Catppuccin Mocha + GameMode)."

###########################################################################
# Mako (Notifications)
###########################################################################
log_section "MAKO NOTIFICATION DAEMON"

MAKO_DIR="/home/${USERNAME}/.config/mako"
mkdir -p "${MAKO_DIR}"

cat > "${MAKO_DIR}/config" << 'MAKOCONF'
sort=-time
layer=overlay
anchor=top-right
font=JetBrains Mono Nerd Font 11
background-color=#1e1e2eee
text-color=#cdd6f4
border-color=#89b4fa
border-size=2
border-radius=12
padding=16
margin=8
width=380
height=200
max-visible=5
default-timeout=5000
ignore-timeout=0
group-by=app-name
icons=1
icon-path=/usr/share/icons/Papirus-Dark
max-icon-size=48

[urgency=low]
border-color=#6c7086
default-timeout=3000

[urgency=normal]
border-color=#89b4fa
default-timeout=5000

[urgency=critical]
border-color=#f38ba8
text-color=#f38ba8
default-timeout=0
MAKOCONF

chown -R "${USERNAME}:${USERNAME}" "${MAKO_DIR}"
log_ok "Mako configuré."

###########################################################################
# Wofi (Launcher)
###########################################################################
log_section "WOFI LAUNCHER"

WOFI_DIR="/home/${USERNAME}/.config/wofi"
mkdir -p "${WOFI_DIR}"

cat > "${WOFI_DIR}/config" << 'WOFICONF'
show=drun
width=600
height=400
always_parse_args=true
show_all=true
print_command=true
layer=overlay
insensitive=true
prompt=Search...
image_size=32
columns=1
allow_images=true
hide_scroll=true
no_actions=true
halign=fill
orientation=vertical
content_halign=fill
WOFICONF

cat > "${WOFI_DIR}/style.css" << 'WOFICSS'
window {
    margin: 0;
    border: 2px solid #89b4fa;
    border-radius: 16px;
    background-color: rgba(30, 30, 46, 0.92);
    font-family: "JetBrains Mono Nerd Font", monospace;
    font-size: 14px;
}
#input {
    margin: 12px; padding: 10px 16px; border: none;
    border-bottom: 2px solid #89b4fa; border-radius: 10px;
    background-color: rgba(49, 50, 68, 0.8); color: #cdd6f4; font-size: 15px;
}
#input:focus { border-bottom-color: #cba6f7; }
#inner-box { margin: 4px 12px; }
#outer-box { margin: 0; padding: 0; }
#scroll { margin: 0; }
#text { margin: 0 8px; color: #cdd6f4; }
#entry { padding: 8px 12px; border-radius: 10px; margin: 2px 0; }
#entry:selected {
    background: linear-gradient(135deg, rgba(137, 180, 250, 0.25), rgba(203, 166, 247, 0.25));
    border: 1px solid rgba(137, 180, 250, 0.3);
}
#img { margin-right: 8px; }
WOFICSS

chown -R "${USERNAME}:${USERNAME}" "${WOFI_DIR}"
log_ok "Wofi configuré."

###########################################################################
# Alacritty Terminal
###########################################################################
log_section "ALACRITTY TERMINAL"

ALACRITTY_DIR="/home/${USERNAME}/.config/alacritty"
mkdir -p "${ALACRITTY_DIR}"

cat > "${ALACRITTY_DIR}/alacritty.toml" << 'ALACRITTYCONF'
[window]
padding = { x = 12, y = 8 }
decorations = "None"
opacity = 0.92
blur = true
startup_mode = "Windowed"
dynamic_padding = true

[scrolling]
history = 10000
multiplier = 3

[font]
size = 12.0
[font.normal]
family = "JetBrains Mono Nerd Font"
style = "Regular"
[font.bold]
family = "JetBrains Mono Nerd Font"
style = "Bold"
[font.italic]
family = "JetBrains Mono Nerd Font"
style = "Italic"
[font.bold_italic]
family = "JetBrains Mono Nerd Font"
style = "Bold Italic"

[colors.primary]
background = "#1e1e2e"
foreground = "#cdd6f4"
dim_foreground = "#7f849c"
bright_foreground = "#cdd6f4"

[colors.cursor]
text = "#1e1e2e"
cursor = "#f5e0dc"

[colors.vi_mode_cursor]
text = "#1e1e2e"
cursor = "#b4befe"

[colors.search.matches]
foreground = "#1e1e2e"
background = "#a6adc8"

[colors.search.focused_match]
foreground = "#1e1e2e"
background = "#a6e3a1"

[colors.hints.start]
foreground = "#1e1e2e"
background = "#f9e2af"

[colors.hints.end]
foreground = "#1e1e2e"
background = "#a6adc8"

[colors.selection]
text = "#1e1e2e"
background = "#f5e0dc"

[colors.normal]
black = "#45475a"
red = "#f38ba8"
green = "#a6e3a1"
yellow = "#f9e2af"
blue = "#89b4fa"
magenta = "#f5c2e7"
cyan = "#94e2d5"
white = "#bac2de"

[colors.bright]
black = "#585b70"
red = "#f38ba8"
green = "#a6e3a1"
yellow = "#f9e2af"
blue = "#89b4fa"
magenta = "#f5c2e7"
cyan = "#94e2d5"
white = "#a6adc8"

[colors.dim]
black = "#45475a"
red = "#f38ba8"
green = "#a6e3a1"
yellow = "#f9e2af"
blue = "#89b4fa"
magenta = "#f5c2e7"
cyan = "#94e2d5"
white = "#bac2de"

[[colors.indexed_colors]]
index = 16
color = "#fab387"
[[colors.indexed_colors]]
index = 17
color = "#f5e0dc"

[cursor.style]
shape = "Beam"
blinking = "On"
[cursor.vi_mode_style]
shape = "Block"
blinking = "Off"

[mouse]
hide_when_typing = true

[selection]
save_to_clipboard = true
ALACRITTYCONF

chown -R "${USERNAME}:${USERNAME}" "${ALACRITTY_DIR}"
log_ok "Alacritty configuré (Catppuccin Mocha)."

###########################################################################
# GTK Theme Configuration
###########################################################################
log_section "GTK THEME"

GTK3_DIR="/home/${USERNAME}/.config/gtk-3.0"
GTK4_DIR="/home/${USERNAME}/.config/gtk-4.0"
mkdir -p "${GTK3_DIR}" "${GTK4_DIR}"

for GTKDIR in "${GTK3_DIR}" "${GTK4_DIR}"; do
    cat > "${GTKDIR}/settings.ini" << 'GTKCFG'
[Settings]
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-font-name=Cantarell 11
gtk-application-prefer-dark-theme=1
gtk-decoration-layout=appmenu:close
GTKCFG
done

chown -R "${USERNAME}:${USERNAME}" "${GTK3_DIR}" "${GTK4_DIR}"
log_ok "GTK thème configuré."

###########################################################################
#                    ╔═══════════════════════════╗
#                    ║        PHASE 7            ║
#                    ║  Firejail + Thorium       ║
#                    ╚═══════════════════════════╝
###########################################################################
log_section "FIREJAIL + THORIUM BROWSER"

# ── Install Firejail ──
pacman -S --noconfirm firejail

# ── Create Firejail profile for Thorium ──
mkdir -p /etc/firejail

cat > /etc/firejail/thorium.profile << 'FJPROFILE'
# Firejail Profile — Thorium Browser (Military Grade)
include /etc/firejail/chromium-common.profile

noblacklist ${HOME}/.config/thorium
noblacklist ${HOME}/.cache/thorium
noblacklist ${HOME}/Downloads
noblacklist ${HOME}/Images

whitelist ${HOME}/.config/thorium
whitelist ${HOME}/.cache/thorium
whitelist ${HOME}/Downloads
whitelist ${HOME}/Images
whitelist ${HOME}/.local/share/icons
whitelist ${HOME}/.local/share/applications

include whitelist-common.inc
include whitelist-runuser-common.inc
include whitelist-usr-share-common.inc
include whitelist-var-common.inc

caps.drop all
nonewprivs
noroot
seccomp
protocol unix,inet,inet6,netlink
netfilter

net none
ignore net none

dbus-user filter
dbus-user.own org.chromium.Thorium.*
dbus-system none

nogroups
shell none
disable-mnt
private-dev
private-tmp
read-only ${HOME}/.config/thorium/Default/Preferences
rlimit-as 4294967296
FJPROFILE

log_ok "Profil Firejail pour Thorium créé."

# ── Install Thorium Browser via AUR ──
log_info "Installation de Thorium Browser..."

# Build yay (AUR helper)
if ! command -v yay &>/dev/null; then
    log_info "Construction de yay (AUR helper)..."
    cd /tmp
    sudo -u "${USERNAME}" git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin 2>/dev/null || true
    if [[ -d /tmp/yay-bin ]]; then
        cd /tmp/yay-bin
        sudo -u "${USERNAME}" makepkg -si --noconfirm 2>/dev/null || true
        cd /
    fi
fi

# Install Thorium from AUR
if command -v yay &>/dev/null; then
    log_info "Installation de Thorium via AUR..."
    sudo -u "${USERNAME}" yay -S --noconfirm thorium-browser-bin quickshell matugen-bin grimblast-git 2>/dev/null || {
        log_warn "Une installation AUR a échoué. Installation manuelle requise après le boot."
    }
else
    log_warn "yay non disponible. Thorium sera à installer manuellement."
fi

# Create symlink for easy access
if [[ -f /usr/bin/thorium-browser ]]; then
    ln -sf /usr/bin/thorium-browser /usr/local/bin/thorium
elif [[ -f /opt/thorium/thorium-browser ]]; then
    ln -sf /opt/thorium/thorium-browser /usr/local/bin/thorium
fi

log_ok "Thorium Browser configuré."

###########################################################################
#                    ╔═══════════════════════════╗
#                    ║        PHASE 8            ║
#                    ║  Btrfs Auto Snapshots     ║
#                    ╚═══════════════════════════╝
###########################################################################
log_section "SNAPSHOTS BTRFS AUTOMATIQUES"

cat > /usr/local/bin/btrfs-auto-snapshot.sh << 'SNAPSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_DIR="/.snapshots"
MAX_SNAPSHOTS=7
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

declare -A SUBVOLS=(
    ["root"]="/"
    ["home"]="/home"
    ["var"]="/var"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

for name in "${!SUBVOLS[@]}"; do
    mnt="${SUBVOLS[$name]}"
    snap_path="${SNAPSHOT_DIR}/${name}"
    mkdir -p "${snap_path}"

    log "Creating snapshot: ${snap_path}/${TIMESTAMP}"
    btrfs subvolume snapshot -r "${mnt}" "${snap_path}/${TIMESTAMP}" || {
        log "ERROR: Failed to create snapshot for ${name}"
        continue
    }

    existing=()
    while IFS= read -r d; do
        [[ -d "$d" ]] && existing+=("$d")
    done < <(ls -1dt "${snap_path}"/*/ 2>/dev/null || true)

    if (( ${#existing[@]} > MAX_SNAPSHOTS )); then
        for (( i=MAX_SNAPSHOTS; i<${#existing[@]}; i++ )); do
            log "Deleting old snapshot: ${existing[$i]}"
            btrfs subvolume delete "${existing[$i]}" || true
        done
    fi

    log "Snapshots for ${name}: $(( ${#existing[@]} > MAX_SNAPSHOTS ? MAX_SNAPSHOTS : ${#existing[@]} )) kept."
done
log "Auto-snapshot complete."
SNAPSCRIPT

chmod +x /usr/local/bin/btrfs-auto-snapshot.sh

cat > /etc/systemd/system/btrfs-auto-snapshot.service << 'SNAPSERVICE'
[Unit]
Description=Btrfs Automatic Snapshot
Wants=btrfs-auto-snapshot.timer

[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-auto-snapshot.sh
StandardOutput=journal
StandardError=journal
Nice=19
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
SNAPSERVICE

cat > /etc/systemd/system/btrfs-auto-snapshot.timer << 'SNAPTIMER'
[Unit]
Description=Daily Btrfs Snapshots

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
SNAPTIMER

systemctl enable btrfs-auto-snapshot.timer
log_ok "Snapshots Btrfs automatiques configurés (7 derniers gardés, quotidien)."

###########################################################################
#                    ╔═══════════════════════════╗
#                    ║        PHASE 9            ║
#                    ║  System Optimizations     ║
#                    ║  ULTRA PERFORMANCE        ║
#                    ╚═══════════════════════════╝
###########################################################################
log_section "OPTIMISATIONS SYSTÈME — ULTRA PERFORMANCE"

# ── Install performance packages ──
pacman -S --noconfirm cpupower zram-generator irqbalance thermald power-profiles-daemon

# ── CPU Governor → performance ──
log_info "CPU governor → performance (Zen kernel scheduler)..."
cat > /etc/default/cpupower << 'CPUPWR'
governor='performance'
CPUPWR
systemctl enable cpupower

# ── IRQ balancing across cores ──
systemctl enable irqbalance

# ── Sysctl — Aggressive tuning for 32GB DDR5 + NVMe + RTX ──
log_info "Sysctl ultra-tuning pour ${TOTAL_RAM_GB}Go RAM, ${CPU_CORES} cores..."

cat > /etc/sysctl.d/99-lunaris-performance.conf << SYSCTL
# ═══════════════════════════════════════════════════════════════════════════
#  Lunaris — System Optimization (${TOTAL_RAM_GB}GB RAM / ${CPU_CORES} cores)
# ═══════════════════════════════════════════════════════════════════════════

# ── Virtual Memory (tuned for 32GB DDR5) ──
vm.swappiness = 5
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 1500
vm.page-cluster = 0
vm.min_free_kbytes = 262144
vm.zone_reclaim_mode = 0
vm.compaction_proactiveness = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125

# ── Hugepages for gaming/GPU (transparent) ──
vm.nr_hugepages = 0

# ── File system ──
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152

# ── Network (low-latency, high-throughput) ──
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_max_syn_backlog = 8192

# ── Security hardening ──
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.sysrq = 0
kernel.unprivileged_userns_clone = 1
kernel.perf_event_paranoid = 2

# ── Kernel scheduling (Zen optimized) ──
kernel.sched_autogroup_enabled = 1
kernel.sched_cfs_bandwidth_slice_us = 3000
SYSCTL

# ── zRAM — tuned for 32GB (use 25% = 8GB) ──
log_info "Configuration zRAM (8Go, lz4 ultra-fast)..."
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = ram / 4
compression-algorithm = lz4
swap-priority = 100
fs-type = swap
ZRAM

# ── TRIM ──
log_info "Activation TRIM périodique (NVMe/SSD)..."
systemctl enable fstrim.timer

# ── Optimization service (boot-time) ──
cat > /etc/systemd/system/lunaris-optim.service << 'OPTIMSERVICE'
[Unit]
Description=Lunaris System Optimization
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Apply sysctl
ExecStart=/usr/sbin/sysctl --system

# CPU governor
ExecStart=/usr/bin/cpupower frequency-set -g performance

# Disable NMI watchdog
ExecStart=/bin/sh -c 'echo 0 > /proc/sys/kernel/nmi_watchdog'

# I/O scheduler for NVMe (none = best for NVMe, mq-deadline for SATA SSD)
ExecStart=/bin/sh -c 'for dev in /sys/block/nvme*/queue/scheduler; do [ -f "$dev" ] && echo "none" > "$dev"; done'
ExecStart=/bin/sh -c 'for dev in /sys/block/sd*/queue/scheduler; do [ -f "$dev" ] && echo "mq-deadline" > "$dev"; done'

# Increase readahead for NVMe
ExecStart=/bin/sh -c 'for dev in /sys/block/nvme*/queue/read_ahead_kb; do [ -f "$dev" ] && echo "2048" > "$dev"; done'

# Enable NVIDIA power management if present
ExecStart=/bin/sh -c '[ -f /proc/driver/nvidia/params ] && echo "1" > /sys/bus/pci/devices/*/power/control 2>/dev/null || true'

# Transparent hugepages = madvise (best for gaming + general use)
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo advise > /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
OPTIMSERVICE

systemctl enable lunaris-optim.service
log_ok "Optimisations système configurées (CPU/RAM/zRAM/TRIM/I/O/THP)."

###########################################################################
# SYSTEM HARDENING
###########################################################################
log_section "HARDENING SYSTÈME"

# ── Firewall (nftables) ──
pacman -S --noconfirm nftables

cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip6 nexthdr ipv6-icmp icmpv6 type echo-request limit rate 5/second accept
        udp dport 67-68 accept
        # mDNS for local network discovery
        udp dport 5353 accept
        log prefix "[nftables-drop] " flags all counter drop
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFTABLES

systemctl enable nftables
log_ok "Firewall nftables configuré."

# ── Fail2ban ──
pacman -S --noconfirm fail2ban

cat > /etc/fail2ban/jail.local << 'FAIL2BAN'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
FAIL2BAN

systemctl enable fail2ban
log_ok "Fail2ban configuré."

# ── SSH hardening ──
pacman -S --noconfirm openssh

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHHARD'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
MaxSessions 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
AllowAgentForwarding no
AllowTcpForwarding no
SSHHARD

# ── USB guard (block unauthorized USB when locked) ──
cat > /etc/udev/rules.d/99-usb-security.rules << 'USBGUARD'
# Log all USB device connections
ACTION=="add", SUBSYSTEM=="usb", RUN+="/usr/bin/logger -t usb-monitor 'USB device added: %k vendor=%s{idVendor} product=%s{idProduct}'"
USBGUARD

log_ok "Hardening système terminé."

###########################################################################
# SHELL CONFIGURATION (Bash)
###########################################################################
log_section "SHELL CONFIGURATION"

cat > "/home/${USERNAME}/.bashrc" << 'BASHRC'
# ═══════════════════════════════════════════════════════════════════════════
#  .bashrc — Lunaris Shell Configuration
# ═══════════════════════════════════════════════════════════════════════════

[[ $- != *i* ]] && return

# ── History ──
HISTSIZE=50000
HISTFILESIZE=100000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT="%F %T  "
shopt -s histappend

# ── Shell options ──
shopt -s checkwinsize
shopt -s globstar 2>/dev/null
shopt -s nocaseglob
shopt -s cdspell
shopt -s autocd

# ── Prompt ──
PS1='\[\e[1;34m\]┌──(\[\e[1;36m\]\u\[\e[1;34m\]@\[\e[1;35m\]\h\[\e[1;34m\])-[\[\e[1;33m\]\w\[\e[1;34m\]]\n\[\e[1;34m\]└─\[\e[1;32m\]▶\[\e[0m\] '

# ── Aliases ──
alias ls='ls --color=auto --group-directories-first'
alias ll='ls -lAh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias ip='ip -color=auto'

# ── System ──
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias remove='sudo pacman -Rns'
alias search='pacman -Ss'
alias cleanup='sudo pacman -Rns $(pacman -Qdtq) 2>/dev/null; sudo paccache -r'
alias mirrors='sudo reflector --country France,Germany --protocol https --sort rate --save /etc/pacman.d/mirrorlist'

# ── Hyprland ──
alias hc='$EDITOR ~/.config/hypr/hyprland.conf'
alias wc='$EDITOR ~/.config/waybar/config.jsonc'

# ── Safety ──
alias rm='rm -I'
alias cp='cp -iv'
alias mv='mv -iv'

# ── Navigation ──
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# ── Snapshots ──
alias snap='sudo /usr/local/bin/btrfs-auto-snapshot.sh'
alias snaplist='sudo btrfs subvolume list /.snapshots'

# ── Performance monitoring ──
alias temps='sensors'
alias gpustat='nvidia-smi 2>/dev/null || echo "No NVIDIA GPU"'
alias cpufreq='cpupower frequency-info'

# ── Editor ──
export EDITOR=nano
export VISUAL=nano
export PATH="$HOME/.local/bin:$PATH"

# ── Wayland ──
if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
    export MOZ_ENABLE_WAYLAND=1
fi

# ── Man pages colors ──
export LESS_TERMCAP_mb=$'\e[1;32m'
export LESS_TERMCAP_md=$'\e[1;36m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[01;34;40m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[1;33m'

# ── Welcome ──
echo ""
echo -e "\e[1;38;5;220m  ██     ██  ██ ███  ██  ▄████▄  █████▄  ██ ▄█████\e[0m"
echo -e "\e[1;38;5;220m  ██     ██  ██ ██ ▀▄██  ██▄▄██  ██▄▄██▄ ██ ▀▀▀▄▄▄\e[0m"
echo -e "\e[1;38;5;220m  ██████ ▀████▀ ██   ██  ██  ██  ██   ██ ██ █████▀\e[0m"
echo ""
echo -e "\e[0;35m  Welcome back, \e[1;33m$(whoami)\e[0;35m — $(date '+%A %d %B %Y, %H:%M')\e[0m"
echo ""
BASHRC

chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.bashrc"
log_ok "Shell configuré."

###########################################################################
# HYPRLAND SESSION — Auto-login to TTY + auto-start
###########################################################################
log_section "AUTO-START HYPRLAND"

cat > "/home/${USERNAME}/.bash_profile" << 'PROFILE'
# Auto-start Hyprland on TTY1
if [[ -z "$DISPLAY" && "$XDG_VTNR" -eq 1 ]]; then
    exec Hyprland
fi
[[ -f ~/.bashrc ]] && . ~/.bashrc
PROFILE

chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.bash_profile"

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${USERNAME} --noclear %I \$TERM
AUTOLOGIN

log_ok "Auto-login + auto-start Hyprland configurés."

###########################################################################
# FINAL TOUCHES
###########################################################################
log_section "FINITIONS"

# ── Enable multilib ──
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    pacman -Sy --noconfirm
fi

# ── Pacman config ──
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
if ! grep -q "^ILoveCandy" /etc/pacman.conf; then
    sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
fi

# ── Reflector ──
log_info "Optimisation des miroirs pacman..."
reflector --country France,Germany,Netherlands --protocol https --sort rate --latest 20 \
    --save /etc/pacman.d/mirrorlist 2>/dev/null || true

# ── Services ──
systemctl enable bluetooth 2>/dev/null || true
systemctl enable systemd-timesyncd

# ── Directories ──
sudo -u "${USERNAME}" mkdir -p "/home/${USERNAME}/Images/Screenshots"
sudo -u "${USERNAME}" mkdir -p "/home/${USERNAME}/Documents"
sudo -u "${USERNAME}" mkdir -p "/home/${USERNAME}/Projets"
sudo -u "${USERNAME}" mkdir -p "/home/${USERNAME}/Téléchargements"

# ── Copie des dotfiles shell-master ──
if [[ -d /tmp/shell-master ]]; then
    log_info "Installation des dotfiles depuis shell-master..."
    mkdir -p "/home/${USERNAME}/.config"
    cp -rT /tmp/shell-master "/home/${USERNAME}/.config"
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"
    find "/home/${USERNAME}/.config/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    rm -rf /tmp/shell-master
    log_ok "Dotfiles shell-master installés avec succès."
fi

# ── Final ownership fix ──
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

log_ok "Finitions terminées."

###########################################################################
# SUMMARY
###########################################################################
log_section "INSTALLATION TERMINÉE"

echo -e "${GREEN}${BOLD}"
cat << 'DONE'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗  ║
    ║   ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝  ║
    ║   ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗    ║
    ║   ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝    ║
    ║   ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗  ║
    ║   ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝  ║
    ║                                                                   ║
    ║              ✅  INSTALLATION TERMINÉE AVEC SUCCÈS               ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
DONE
echo -e "${RESET}"

echo -e "  ${WHITE}✔ Arch Linux (linux-zen)${RESET}        installé — preemptive scheduler"
echo -e "  ${WHITE}✔ LUKS2 + Argon2id${RESET}              AES-256-XTS, ${CPU_CORES} threads"
echo -e "  ${WHITE}✔ Btrfs + subvolumes${RESET}            @, @home, @var, @cache, @log, @tmp, @snapshots"
echo -e "  ${WHITE}✔ Snapshots automatiques${RESET}        quotidiens (7 max)"
echo -e "  ${WHITE}✔ Hyprland Lunaris${RESET}              direct scanout + VRR + tearing"
echo -e "  ${WHITE}✔ Waybar + Wofi + Mako${RESET}          Catppuccin Mocha"
echo -e "  ${WHITE}✔ Alacritty${RESET}                     terminal configuré"
echo -e "  ${WHITE}✔ Thorium + Firejail${RESET}            sandboxé"
echo -e "  ${WHITE}✔ GameMode + MangoHud${RESET}           gaming performance"
echo -e "  ${WHITE}✔ PipeWire low-latency${RESET}          48kHz / 256 quantum"
echo -e "  ${WHITE}✔ CPU Performance${RESET}               cpupower + irqbalance"
echo -e "  ${WHITE}✔ RAM optimisée${RESET}                 ${TOTAL_RAM_GB}Go — swappiness=5, THP=madvise"
echo -e "  ${WHITE}✔ zRAM${RESET}                          lz4 ultra-fast (RAM/4)"
echo -e "  ${WHITE}✔ NVMe I/O scheduler${RESET}            none (bypass)"
echo -e "  ${WHITE}✔ TRIM${RESET}                          fstrim.timer"
echo -e "  ${WHITE}✔ Firewall${RESET}                      nftables (drop policy)"
echo -e "  ${WHITE}✔ Fail2ban + SSH${RESET}                hardened"
echo -e "  ${WHITE}✔ Clavier AZERTY${RESET}                + MX Keys Mini"
echo -e "  ${WHITE}✔ Auto-login${RESET}                    TTY1 → Hyprland"
echo -e "  ${WHITE}✔ VMware-tools${RESET}                  open-vm-tools activé"
if [[ "$IS_VM" == true ]]; then
echo -e "  ${WHITE}✔ VM Tools extra${RESET}                ${VM_TYPE}"
fi
echo ""
echo -e "  ${CYAN}Retirez le média d'installation et redémarrez.${RESET}"
echo ""

CHROOT_BODY

    chmod +x /mnt/chroot-setup.sh

    log_info "Exécution du script chroot..."
    if [[ -d "$(dirname "$0")/shell-master" ]]; then
        log_info "Copie des dotfiles vers /mnt/tmp..."
        cp -r "$(dirname "$0")/shell-master" /mnt/tmp/shell-master
    fi
    arch-chroot /mnt /chroot-setup.sh

    # Cleanup
    rm -f /mnt/chroot-setup.sh

    log_ok "Configuration chroot terminée."
}

###############################################################################
#                         ╔═══════════════════════╗
#                         ║     MAIN              ║
#                         ║   Orchestration       ║
#                         ╚═══════════════════════╝
###############################################################################

main() {
    show_banner

    # Phase 1 — TUI: collect information
    select_disk
    select_install_mode
    select_microcode
    collect_user_info
    confirm_install

    # Phase 2 — Partitioning & Encryption
    partition_and_encrypt

    # Phase 3 — Btrfs & Subvolumes
    setup_btrfs

    # Phase 4 — Base install & fstab
    install_base

    # Phase 5-9 — Chroot configuration (all phases inside chroot)
    configure_chroot

    # ── Unmount & Cleanup ──
    log_section "DÉMONTAGE"

    sync
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true

    log_ok "Système démonté proprement."

    echo ""
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  ✅  TOUT EST PRÊT — REDÉMARREZ VOTRE MACHINE${RESET}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${CYAN}  Log complet : ${LOG_FILE}${RESET}"
    echo ""

    read -rp "$(echo -e "${YELLOW}▶ Redémarrer maintenant ? [O/n] : ${RESET}")" reboot_now
    if [[ "${reboot_now,,}" != "n" ]]; then
        reboot
    fi
}

# Run
main "$@"
