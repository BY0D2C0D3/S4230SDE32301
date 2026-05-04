#!/usr/bin/env bash
###############################################################################
#
#   arch-installer.sh
#
#   Single-entry installer for Arch Linux on a VMware Workstation Pro 17 guest.
#   Two phases dispatched automatically based on context:
#
#     1. bootstrap (default if running as root from the Arch ISO live env):
#          - Wipes target disk, creates GPT (ESP + LUKS).
#          - LUKS2 with Argon2id (RAM-tuned).
#          - BTRFS with Snapper-friendly subvolumes (zstd:3).
#          - pacstrap + chroot (locale fr_FR, AZERTY, NetworkManager, VMware tools).
#          - Installs systemd-boot UEFI with VMware-aware initramfs modules.
#          - Copies this script + the local imperative-dots/ folder into the
#            new system, then arms a one-shot .bash_profile launcher so the
#            DOTFILES phase auto-runs at first user login.
#
#     2. dotfiles (auto-fired at first login by the bash_profile hook):
#          - Initialises a local git repo inside ~/imperative-dots/ to satisfy
#            install.sh's "local dev repo" detection (so it uses the bundled,
#            telemetry-stripped copy and does NOT clone upstream).
#          - Hands off to imperative-dots/install.sh as the user.
#          - Removes its own one-shot launcher.
#
#   Usage on the Arch ISO live env (after booting the VM on the live ISO):
#       1. mount your host share / USB containing this folder somewhere.
#       2. cd /path/to/ARCH\ AUTO\ INSTALL
#       3. sudo bash arch-installer.sh
#       (the script handles everything from there: phase 1 -> reboot -> phase 2.)
#
###############################################################################

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Resolve own location (so the bootstrap can find the bundled imperative-dots)
# -----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# -----------------------------------------------------------------------------
# Phase dispatch
#   --phase=bootstrap | --phase=dotfiles | --phase=postmenu | --phase=auto (default)
#
#   postmenu is internal: re-entered by the post-install menu after the user
#   exits the chroot dive, so the menu re-appears WITHOUT re-running the full
#   bootstrap (which would re-partition the disk).
# -----------------------------------------------------------------------------
PHASE="auto"
for arg in "$@"; do
    case "$arg" in
        --phase=bootstrap) PHASE="bootstrap" ;;
        --phase=dotfiles)  PHASE="dotfiles"  ;;
        --phase=postmenu)  PHASE="postmenu"  ;;
        --phase=auto)      PHASE="auto"      ;;
    esac
done

if [[ "$PHASE" == "auto" ]]; then
    if [[ "$(id -u)" -eq 0 ]] && [[ -d /sys/firmware/efi/efivars ]] \
       && [[ ! -b /dev/mapper/cryptroot ]] && grep -q archiso /proc/cmdline 2>/dev/null; then
        PHASE="bootstrap"
    elif [[ "$(id -u)" -ne 0 ]] && [[ -d "$HOME/imperative-dots" ]]; then
        PHASE="dotfiles"
    elif [[ "$(id -u)" -eq 0 ]]; then
        PHASE="bootstrap"
    else
        PHASE="dotfiles"
    fi
fi

# -----------------------------------------------------------------------------
# Colors / logging
# -----------------------------------------------------------------------------
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

LOG_FILE="/tmp/arch-installer-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "${GREEN}[ OK ]${RESET}   $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}   $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERR ]${RESET}   $*" | tee -a "$LOG_FILE"; }
log_section() {
    {
        echo -e "\n${MAGENTA}${BOLD}--------------------------------------------------------${RESET}"
        echo -e "${MAGENTA}${BOLD}  $*${RESET}"
        echo -e "${MAGENTA}${BOLD}--------------------------------------------------------${RESET}\n"
    } | tee -a "$LOG_FILE"
}
die() { log_error "$*"; exit 1; }

###############################################################################
# PHASE 2 -- DOTFILES (runs as the user post-reboot)
###############################################################################
run_dotfiles_phase() {
    log_section "DOTFILES PHASE (imperative-dots)"

    [[ "$(id -u)" -ne 0 ]] || die "Do NOT run the dotfiles phase as root."

    local DOTS_DIR="$HOME/imperative-dots"
    [[ -d "$DOTS_DIR" ]] || die "Missing $DOTS_DIR (was the bootstrap phase completed?)."
    [[ -f "$DOTS_DIR/install.sh" ]] || die "Missing $DOTS_DIR/install.sh."
    [[ -d "$DOTS_DIR/.config" ]] || die "Missing $DOTS_DIR/.config -- payload incomplete."

    # install.sh's "local dev repo" path requires a .git directory in $(pwd).
    # We initialise a throwaway local repo so it uses the bundled, telemetry-
    # stripped copy and does NOT clone upstream.
    if [[ ! -d "$DOTS_DIR/.git" ]]; then
        log_info "Initialising local git repo so install.sh treats this folder as a dev repo..."
        ( cd "$DOTS_DIR" \
          && git init -q \
          && git add -A \
          && git -c user.name=local -c user.email=local@local commit -q -m "bundled" ) \
        || log_warn "git init failed -- install.sh may fall back to upstream clone."
    fi

    # Disarm the one-shot first-login hook (idempotent) BEFORE running the
    # interactive installer, so a Ctrl+C doesn't leave it re-firing.
    local HOOK_MARK="# arch-installer:dotfiles-once"
    if [[ -f "$HOME/.bash_profile" ]] && grep -qF "$HOOK_MARK" "$HOME/.bash_profile"; then
        log_info "Removing first-login hook from ~/.bash_profile..."
        sed -i "/$HOOK_MARK START/,/$HOOK_MARK END/d" "$HOME/.bash_profile"
    fi

    log_info "Handing off to imperative-dots/install.sh..."
    cd "$DOTS_DIR"
    exec bash ./install.sh "$@"
}

###############################################################################
# Input sanitization helpers (used by collect_user_info)
###############################################################################

# Reject control chars (C0/C1/DEL) + invisible/dangerous Unicode in the BMP:
# zero-width spaces, BiDi overrides, formatting controls, BOM.
_has_invisible_chars() {
    local s="$1"
    if [[ "$s" == *[$'\x01'-$'\x1f']* ]] || [[ "$s" == *$'\x7f'* ]]; then
        return 0
    fi
    if LC_ALL=C grep -qE $'\xE2\x80[\x8B-\x8F\xAA-\xAE]|\xE2\x81[\xA0-\xA4\xAA-\xAF]|\xEF\xBB\xBF|\xEF\xBF[\xB9-\xBB]' <<<"$s" 2>/dev/null; then
        return 0
    fi
    return 1
}

_is_valid_utf8() {
    LC_ALL=C printf %s "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

# Username: POSIX portable filename, 1..32 chars, must start with letter/underscore.
# Reject reserved system names.
validate_username() {
    local u="$1"
    local reserved=(root daemon bin sys sync games man lp mail news uucp proxy www-data
                    backup list irc gnats nobody systemd-network systemd-resolve
                    systemd-timesync messagebus syslog _apt tss uuidd tcpdump avahi
                    cups-pk-helper geoclue gnome-initial-setup hplip kernoops pulse
                    rtkit saned speech-dispatcher whoopsie polkitd)
    [[ -z "$u" ]] && { log_warn "Empty username."; return 1; }
    (( ${#u} < 1 || ${#u} > 32 )) && { log_warn "Invalid length (1-32 chars)."; return 1; }
    if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
        log_warn "Invalid format. Required: ^[a-z_][a-z0-9_-]*\$? (POSIX portable)."
        return 1
    fi
    local r
    for r in "${reserved[@]}"; do
        [[ "$u" == "$r" ]] && { log_warn "Reserved system name: $r"; return 1; }
    done
    return 0
}

# Hostname: RFC 1123 -- alphanumeric + hyphens, 1..63 chars/label, total 1..253.
validate_hostname() {
    local h="$1"
    [[ -z "$h" ]] && { log_warn "Empty hostname."; return 1; }
    (( ${#h} > 253 )) && { log_warn "Hostname too long (max 253)."; return 1; }
    if ! [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_warn "Invalid hostname (RFC 1123: alphanum + hyphens, no leading/trailing hyphen)."
        return 1
    fi
    if [[ "$h" =~ ^[0-9]+$ ]]; then
        log_warn "Pure-numeric hostname forbidden."
        return 1
    fi
    return 0
}

# Password / passphrase: reject control chars, invisible Unicode, BiDi overrides,
# enforce min length, reject shell-meta chars (RCE risk in heredoc/eval), reject
# the ":" char (chpasswd field separator).
validate_credential() {
    local pw="$1" minlen="${2:-12}" label="${3:-credential}"
    if [[ -z "$pw" ]]; then log_warn "$label is empty."; return 1; fi
    if (( ${#pw} < minlen )); then log_warn "$label too short (min ${minlen} chars)."; return 1; fi
    if (( ${#pw} > 1024 )); then log_warn "$label too long (>1024)."; return 1; fi
    if ! _is_valid_utf8 "$pw"; then log_warn "$label contains invalid UTF-8 bytes."; return 1; fi
    if _has_invisible_chars "$pw"; then
        log_warn "$label contains invisible/control chars (zero-width, BiDi, BOM, NUL...)."
        return 1
    fi
    if [[ "$pw" == *:* ]]; then log_warn "$label contains ':' (forbidden by chpasswd)."; return 1; fi
    if [[ "$pw" == *[\"\$\`\\]* ]]; then
        log_warn "$label contains shell-reserved chars (\" \$ \` \\) -- refused."
        return 1
    fi
    if [[ "$pw" =~ ^[[:space:]]+$ ]]; then log_warn "$label is whitespace-only."; return 1; fi
    if [[ "$pw" =~ ^[[:space:]] ]] || [[ "$pw" =~ [[:space:]]$ ]]; then
        log_warn "$label has leading/trailing whitespace -- refused (likely paste mistake)."
        return 1
    fi
    case "${pw,,}" in
        password|password123|admin|admin123|root|root123|toor|123456789012|qwertyuiopas|azertyuiopq)
            log_warn "$label is in the trivial-password blacklist."; return 1 ;;
    esac
    return 0
}

# Generate a Windows-style hostname matching pattern DESKTOP-YYXYYXY
# where Y = uppercase letter [A-Z] and X = digit [0-9].
# Example: DESKTOP-AB3CD4E
gen_windows_hostname() {
    local letters="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local digits="0123456789"
    local h="DESKTOP-"
    h+="${letters:RANDOM%26:1}"   # Y
    h+="${letters:RANDOM%26:1}"   # Y
    h+="${digits:RANDOM%10:1}"    # X
    h+="${letters:RANDOM%26:1}"   # Y
    h+="${letters:RANDOM%26:1}"   # Y
    h+="${digits:RANDOM%10:1}"    # X
    h+="${letters:RANDOM%26:1}"   # Y
    printf '%s' "$h"
}

###############################################################################
# PHASE 1 -- BOOTSTRAP (runs as root from the Arch ISO)
###############################################################################
run_bootstrap_phase() {
    cleanup_on_error() {
        local line="$1"
        log_error "Failure at line ${line}. See ${LOG_FILE}"
        log_warn "Attempting cleanup of /mnt mounts and LUKS map..."
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        exit 1
    }
    trap 'cleanup_on_error $LINENO' ERR

    [[ "$(id -u)" -eq 0 ]] || die "Bootstrap phase must run as root from the Arch ISO."

    # Auto-detect firmware mode: UEFI -> systemd-boot, BIOS -> GRUB i386-pc.
    # VMware (firmware="efi" vs "bios" in .vmx) and bare-metal both supported.
    local FIRMWARE_MODE
    if [[ -d /sys/firmware/efi/efivars ]]; then
        FIRMWARE_MODE="uefi"
        log_ok "Firmware: UEFI detected (systemd-boot will be used)"
    else
        FIRMWARE_MODE="bios"
        log_ok "Firmware: BIOS Legacy detected (GRUB i386-pc will be used)"
    fi

    local VM_TYPE
    VM_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
    if [[ "$VM_TYPE" != "vmware" ]]; then
        log_warn "Detected virtualization: '${VM_TYPE}' (expected 'vmware'). Continuing."
    else
        log_ok "VMware Workstation guest detected"
    fi

    # Locate the bundled imperative-dots/ folder
    local DOTS_SRC="$SCRIPT_DIR/imperative-dots"
    [[ -d "$DOTS_SRC" ]] || die "Bundled folder not found: $DOTS_SRC (must sit next to this script)."
    [[ -f "$DOTS_SRC/install.sh" ]] || die "$DOTS_SRC/install.sh missing."

    # ------------------------------ Pre-flight ------------------------------
    log_section "PRE-FLIGHT"

    log_info "Checking network..."
    ping -c 1 -W 3 archlinux.org &>/dev/null \
        || die "No network. Bring up Ethernet (DHCP) or run 'iwctl', then re-run."
    log_ok "Network OK"

    log_info "Tuning live-ISO pacman..."
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf

    log_info "Refreshing keyring..."
    pacman -Sy --noconfirm archlinux-keyring &>/dev/null || true

    log_info "Installing required tools on live ISO..."
    pacman -S --needed --noconfirm git wget gptfdisk btrfs-progs arch-install-scripts \
        dosfstools cryptsetup nano reflector >/dev/null

    local cmd
    for cmd in sgdisk cryptsetup mkfs.btrfs pacstrap arch-chroot genfstab blkid lsblk \
               wipefs partprobe udevadm reflector; do
        command -v "$cmd" &>/dev/null || die "Missing required tool: ${cmd}"
    done
    log_ok "Live environment ready"

    # ------------------------- Resource detection ---------------------------
    local TOTAL_RAM_KB TOTAL_RAM_GB CPU_CORES CPU_VENDOR CPU_UCODE
    TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
    log_info "Detected RAM: ${TOTAL_RAM_GB} GB, CPU cores: ${CPU_CORES}"

    CPU_VENDOR="$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')"
    case "$CPU_VENDOR" in
        GenuineIntel) CPU_UCODE="intel-ucode" ;;
        AuthenticAMD) CPU_UCODE="amd-ucode"   ;;
        *)            CPU_UCODE="" ;;
    esac
    log_info "CPU vendor: ${CPU_VENDOR} -> ucode: ${CPU_UCODE:-none}"

    # ----------------------- Disk selection (TUI) ---------------------------
    log_section "DISK SELECTION"
    echo -e "${WHITE}Available disks:${RESET}\n"

    local -a disks=()
    local i=1 dname dsize dtype dmodel TARGET_DISK
    while IFS= read -r line; do
        dname="$(echo "$line"  | awk '{print $1}')"
        dtype="$(echo "$line"  | awk '{print $2}')"
        dsize="$(echo "$line"  | awk '{print $3}')"
        dmodel="$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}')"
        [[ "$dname" == loop* ]] && continue
        [[ "$dname" == sr* ]]   && continue
        disks+=("/dev/$dname")
        echo -e "  ${CYAN}[$i]${RESET}  /dev/${dname}  --  ${GREEN}${dsize}${RESET}  (${dtype}) ${DIM}${dmodel}${RESET}"
        ((i++))
    done < <(lsblk -dpno NAME,TYPE,SIZE,MODEL | grep -E 'disk' | sed 's|/dev/||')

    [[ ${#disks[@]} -eq 0 ]] && die "No disk detected."

    echo ""
    while true; do
        read -rp "$(echo -e "${YELLOW}> Pick the target disk number: ${RESET}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            TARGET_DISK="${disks[$((choice-1))]}"
            break
        fi
        log_warn "Invalid choice. Try again."
    done
    echo -e "\n${GREEN}> Selected disk: ${BOLD}${TARGET_DISK}${RESET}\n"

    # --------------------- Account / hostname / passwords -------------------
    log_section "USER INFORMATION"

    local USERNAME HOSTNAME ROOT_PASSWORD USER_PASSWORD LUKS_PASSPHRASE rp2 up2 lp2

    # Username (validated, retry on error). Empty input -> default "lunaris".
    echo -e "  ${DIM}(Leave empty and press Enter to use the default username '${BOLD}lunaris${RESET}${DIM}'.)${RESET}"
    while true; do
        read -rp "$(echo -e "${YELLOW}> Username [lunaris]: ${RESET}")" USERNAME
        USERNAME="${USERNAME:-lunaris}"
        if validate_username "$USERNAME"; then
            echo -e "  ${GREEN}> User: ${BOLD}${USERNAME}${RESET}"
            break
        fi
    done
    echo ""

    # Root password (>=12 chars, sanitized)
    while true; do
        read -srp "$(echo -e "${YELLOW}> ROOT password (>=12 chars): ${RESET}")" ROOT_PASSWORD; echo ""
        read -srp "$(echo -e "${YELLOW}> Confirm ROOT password: ${RESET}")" rp2; echo ""
        if [[ "$ROOT_PASSWORD" != "$rp2" ]]; then log_warn "Passwords do not match."; continue; fi
        validate_credential "$ROOT_PASSWORD" 12 "Root password" || continue
        echo -e "  ${GREEN}> Root password set (${#ROOT_PASSWORD} chars).${RESET}"
        break
    done
    echo ""

    # User password (>=12 chars, must differ from username)
    while true; do
        read -srp "$(echo -e "${YELLOW}> Password for ${USERNAME} (>=12 chars): ${RESET}")" USER_PASSWORD; echo ""
        read -srp "$(echo -e "${YELLOW}> Confirm password: ${RESET}")" up2; echo ""
        if [[ "$USER_PASSWORD" != "$up2" ]]; then log_warn "Passwords do not match."; continue; fi
        validate_credential "$USER_PASSWORD" 12 "User password" || continue
        if [[ "${USER_PASSWORD,,}" == "${USERNAME,,}" ]]; then
            log_warn "User password identical to username -- refused."; continue
        fi
        echo -e "  ${GREEN}> User password set (${#USER_PASSWORD} chars).${RESET}"
        break
    done
    echo ""

    # LUKS passphrase (>=12 chars, sanitized)
    while true; do
        read -srp "$(echo -e "${YELLOW}> LUKS passphrase (disk encryption, >=12 chars): ${RESET}")" LUKS_PASSPHRASE; echo ""
        read -srp "$(echo -e "${YELLOW}> Confirm LUKS passphrase: ${RESET}")" lp2; echo ""
        if [[ "$LUKS_PASSPHRASE" != "$lp2" ]]; then log_warn "Passphrases do not match."; continue; fi
        validate_credential "$LUKS_PASSPHRASE" 12 "LUKS passphrase" || continue
        echo -e "  ${GREEN}> LUKS passphrase set (${#LUKS_PASSPHRASE} chars).${RESET}"
        break
    done
    echo ""

    # Hostname (RFC 1123). Empty input -> generate a Windows-style hostname
    # matching DESKTOP-YYXYYXY (Y=A-Z, X=0-9), e.g. DESKTOP-AB3CD4E.
    local DEFAULT_HOSTNAME
    DEFAULT_HOSTNAME="$(gen_windows_hostname)"
    echo -e "  ${DIM}(Leave empty and press Enter to use a Windows-style random hostname"
    echo -e "   matching the pattern ${BOLD}DESKTOP-YYXYYXY${RESET}${DIM} -- Y=A-Z, X=0-9.)${RESET}"
    while true; do
        read -rp "$(echo -e "${YELLOW}> Hostname [${DEFAULT_HOSTNAME}]: ${RESET}")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
        if validate_hostname "$HOSTNAME"; then
            echo -e "  ${GREEN}> Hostname: ${BOLD}${HOSTNAME}${RESET}"
            break
        fi
        # Re-roll default for next retry so user sees a different suggestion
        DEFAULT_HOSTNAME="$(gen_windows_hostname)"
    done
    echo ""

    # ------------------------ Summary + confirm WIPE ------------------------
    log_section "INSTALL SUMMARY"
    echo -e "  ${WHITE}Target disk     :${RESET}  ${BOLD}${TARGET_DISK}${RESET}"
    echo -e "  ${WHITE}Firmware mode   :${RESET}  ${BOLD}${FIRMWARE_MODE}${RESET}  ($([[ "$FIRMWARE_MODE" == "uefi" ]] && echo systemd-boot || echo 'GRUB i386-pc'))"
    echo -e "  ${WHITE}Username        :${RESET}  ${BOLD}${USERNAME}${RESET}"
    echo -e "  ${WHITE}Hostname        :${RESET}  ${BOLD}${HOSTNAME}${RESET}"
    echo -e "  ${WHITE}Microcode       :${RESET}  ${BOLD}${CPU_UCODE:-none}${RESET}"
    echo -e "  ${WHITE}Encryption      :${RESET}  ${BOLD}LUKS2 + Argon2id (AES-256-XTS)${RESET}"
    echo -e "  ${WHITE}Filesystem      :${RESET}  ${BOLD}BTRFS (subvolumes + zstd:3)${RESET}"
    echo -e "  ${WHITE}RAM detected    :${RESET}  ${BOLD}${TOTAL_RAM_GB} GB${RESET}"
    echo -e "  ${WHITE}CPU cores       :${RESET}  ${BOLD}${CPU_CORES}${RESET}"
    echo -e "  ${WHITE}VM detected     :${RESET}  ${BOLD}${VM_TYPE}${RESET}"
    echo ""
    echo -e "${RED}${BOLD}  /!\\  WARNING: ALL DATA ON ${TARGET_DISK} WILL BE WIPED  /!\\${RESET}"
    echo ""

    local CONFIRM_WIPE
    read -rp "$(echo -e "${YELLOW}> Type 'WIPE' to confirm and start the install: ${RESET}")" CONFIRM_WIPE
    [[ "$CONFIRM_WIPE" == "WIPE" ]] || die "Install cancelled by user."
    echo ""
    log_ok "Confirmed. Starting installation..."
    sleep 1

    # ---------------------- Partitioning + LUKS2 ----------------------------
    log_section "PARTITIONING & LUKS2"

    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true

    local LOG_SEC LUKS_SECTOR_SIZE
    LOG_SEC="$(blkid -p -s LOGICAL_SECTOR_SIZE -o value "${TARGET_DISK}" 2>/dev/null || echo 512)"
    LUKS_SECTOR_SIZE=512
    [[ "$LOG_SEC" == "4096" ]] && LUKS_SECTOR_SIZE=4096
    log_info "Logical sector size: ${LUKS_SECTOR_SIZE}"

    log_info "Wiping signatures on ${TARGET_DISK}..."
    wipefs -af "${TARGET_DISK}" 2>/dev/null || true
    sgdisk --zap-all "${TARGET_DISK}" >/dev/null
    partprobe "${TARGET_DISK}" 2>/dev/null || true
    sleep 2

    local SUFFIX="" ESP_PART="" BOOT_PART="" BIOS_PART="" ROOT_PART
    [[ "${TARGET_DISK}" =~ [0-9]$ ]] && SUFFIX="p"

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        log_info "Creating GPT layout: ESP 512MB FAT32 + LUKS root..."
        sgdisk -o \
               -n 1:0:+512M -t 1:ef00 -c 1:"EFI" \
               -n 2:0:0     -t 2:8309 -c 2:"CRYPTROOT" \
               "${TARGET_DISK}"
    else
        # BIOS Legacy: bios_boot (1MB ef02) for GRUB stage1.5 + /boot ext4
        # (unencrypted, so GRUB can read kernel/initramfs before LUKS unlock)
        # + LUKS root.
        log_info "Creating GPT layout: BIOSBOOT 1MB + /boot ext4 512MB + LUKS root..."
        sgdisk -o \
               -n 1:0:+1M    -t 1:ef02 -c 1:"BIOSBOOT" \
               -n 2:0:+512M  -t 2:8300 -c 2:"BOOT" \
               -n 3:0:0      -t 3:8309 -c 3:"CRYPTROOT" \
               "${TARGET_DISK}"
    fi

    sync
    partprobe "${TARGET_DISK}" 2>/dev/null || true
    udevadm settle --timeout=15 2>/dev/null || sleep 3

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        ESP_PART="${TARGET_DISK}${SUFFIX}1"
        ROOT_PART="${TARGET_DISK}${SUFFIX}2"
        [[ -b "$ESP_PART"  ]] || die "ESP partition ${ESP_PART} missing."
        [[ -b "$ROOT_PART" ]] || die "Root partition ${ROOT_PART} missing."

        log_info "Formatting ESP (FAT32) on ${ESP_PART}..."
        mkfs.fat -F 32 -n EFI "${ESP_PART}" >/dev/null
    else
        BIOS_PART="${TARGET_DISK}${SUFFIX}1"
        BOOT_PART="${TARGET_DISK}${SUFFIX}2"
        ROOT_PART="${TARGET_DISK}${SUFFIX}3"
        [[ -b "$BIOS_PART" ]] || die "BIOS_BOOT partition ${BIOS_PART} missing."
        [[ -b "$BOOT_PART" ]] || die "/boot partition ${BOOT_PART} missing."
        [[ -b "$ROOT_PART" ]] || die "Root partition ${ROOT_PART} missing."

        log_info "Formatting /boot (ext4) on ${BOOT_PART}..."
        mkfs.ext4 -F -L BOOT "${BOOT_PART}" >/dev/null
        # bios_boot stays raw -- GRUB writes its embedded core.img there.
    fi

    # Argon2id parameters tuned to RAM (avoid OOM in low-RAM VMs).
    local ARGON_PARALLEL ARGON_MEM
    ARGON_PARALLEL=$(( CPU_CORES > 4 ? 4 : CPU_CORES ))
    if   (( TOTAL_RAM_GB >= 64 )); then ARGON_MEM=4194304   # 4 GiB
    elif (( TOTAL_RAM_GB >= 32 )); then ARGON_MEM=2097152   # 2 GiB
    elif (( TOTAL_RAM_GB >= 16 )); then ARGON_MEM=1048576   # 1 GiB
    elif (( TOTAL_RAM_GB >=  8 )); then ARGON_MEM=524288    # 512 MiB
    elif (( TOTAL_RAM_GB >=  4 )); then ARGON_MEM=262144    # 256 MiB
    else                                ARGON_MEM=131072    # 128 MiB
    fi

    log_info "LUKS2 + Argon2id (mem=${ARGON_MEM} KiB, parallel=${ARGON_PARALLEL})..."
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --pbkdf-memory "${ARGON_MEM}" \
        --pbkdf-parallel "${ARGON_PARALLEL}" \
        --pbkdf-force-iterations 4 \
        --sector-size "${LUKS_SECTOR_SIZE}" \
        --label CRYPTROOT \
        --batch-mode \
        "${ROOT_PART}"
    log_ok "LUKS2 header written"

    log_info "Opening cryptroot..."
    echo -n "${LUKS_PASSPHRASE}" | cryptsetup open \
        --type luks2 \
        --perf-no_read_workqueue \
        --perf-no_write_workqueue \
        --allow-discards \
        "${ROOT_PART}" cryptroot
    [[ -b /dev/mapper/cryptroot ]] || die "/dev/mapper/cryptroot missing."

    cryptsetup luksHeaderBackup "${ROOT_PART}" --header-backup-file /tmp/luks-header.img 2>/dev/null || true
    chmod 600 /tmp/luks-header.img 2>/dev/null || true
    log_warn "LUKS header backup at /tmp/luks-header.img -- copy it OFF this disk."

    local LUKS_UUID
    LUKS_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
    log_ok "LUKS UUID: ${LUKS_UUID}"

    # ------------------------ BTRFS + Subvolumes ----------------------------
    log_section "BTRFS LAYOUT"

    log_info "mkfs.btrfs on /dev/mapper/cryptroot..."
    mkfs.btrfs -f -L ARCHROOT /dev/mapper/cryptroot >/dev/null

    log_info "Creating subvolumes (@, @home, @cache, @log, @tmp, @snapshots)..."
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@          >/dev/null
    btrfs subvolume create /mnt/@home      >/dev/null
    btrfs subvolume create /mnt/@cache     >/dev/null
    btrfs subvolume create /mnt/@log       >/dev/null
    btrfs subvolume create /mnt/@tmp       >/dev/null
    btrfs subvolume create /mnt/@snapshots >/dev/null
    umount /mnt

    local BTRFS_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2,commit=120"
    local BTRFS_NOCOW="noatime,nodatacow,discard=async,space_cache=v2,commit=120"

    log_info "Mounting subvolumes..."
    mount -o "subvol=@,${BTRFS_OPTS}" /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/{home,var/cache,var/log,var/tmp,.snapshots,boot}
    chattr +C /mnt/var/cache 2>/dev/null || true
    chattr +C /mnt/var/log   2>/dev/null || true
    chattr +C /mnt/var/tmp   2>/dev/null || true
    mount -o "subvol=@home,${BTRFS_OPTS}"      /dev/mapper/cryptroot /mnt/home
    mount -o "subvol=@cache,${BTRFS_NOCOW}"    /dev/mapper/cryptroot /mnt/var/cache
    mount -o "subvol=@log,${BTRFS_OPTS}"       /dev/mapper/cryptroot /mnt/var/log
    mount -o "subvol=@tmp,${BTRFS_NOCOW}"      /dev/mapper/cryptroot /mnt/var/tmp
    mount -o "subvol=@snapshots,${BTRFS_OPTS}" /dev/mapper/cryptroot /mnt/.snapshots

    if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
        mount "${ESP_PART}" /mnt/boot
    else
        mount "${BOOT_PART}" /mnt/boot
    fi

    log_ok "Mount layout:"
    findmnt --target /mnt | tee -a "$LOG_FILE"

    # --------------------------- Pacstrap base ------------------------------
    log_section "PACSTRAP (base + linux + VMware tools)"

    log_info "Optimizing mirrors via reflector..."
    reflector --country France,Germany,Netherlands --protocol https --sort rate --latest 20 \
        --save /etc/pacman.d/mirrorlist 2>/dev/null \
        || reflector --protocol https --sort rate --latest 20 --save /etc/pacman.d/mirrorlist 2>/dev/null \
        || true

    local PACSTRAP_PKGS=(
        base linux linux-firmware
        btrfs-progs cryptsetup
        networkmanager
        sudo nano vim git wget curl
        man-db man-pages texinfo
        dosfstools e2fsprogs util-linux which
        pciutils usbutils
        mkinitcpio
        arch-install-scripts
        open-vm-tools xf86-video-vmware gtkmm3
    )
    [[ -n "$CPU_UCODE" ]] && PACSTRAP_PKGS+=("$CPU_UCODE")
    # Bootloader packages: GRUB always (used in BIOS, also handy in UEFI for
    # rescue), efibootmgr only meaningful in UEFI (harmless in BIOS).
    PACSTRAP_PKGS+=(grub)
    [[ "$FIRMWARE_MODE" == "uefi" ]] && PACSTRAP_PKGS+=(efibootmgr)

    log_info "Running pacstrap (this can take a while)..."
    pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"
    log_ok "Base system installed"

    log_info "Generating /etc/fstab (UUID-based)..."
    genfstab -U /mnt >> /mnt/etc/fstab

    # --------------------- Stage payload + chroot env -----------------------
    log_section "PAYLOAD STAGING"

    log_info "Copying bundled imperative-dots/ -> /mnt/home/${USERNAME}/imperative-dots/ ..."
    mkdir -p "/mnt/home/${USERNAME}/imperative-dots"
    # Preserve perms; exclude any local .git so the dotfiles phase init is clean.
    cp -a "${DOTS_SRC}/." "/mnt/home/${USERNAME}/imperative-dots/"
    rm -rf "/mnt/home/${USERNAME}/imperative-dots/.git" 2>/dev/null || true

    log_info "Copying this installer into /mnt/home/${USERNAME}/arch-installer.sh ..."
    cp -a "${SCRIPT_PATH}" "/mnt/home/${USERNAME}/arch-installer.sh"
    chmod +x "/mnt/home/${USERNAME}/arch-installer.sh"

    cat > /mnt/root/.bootstrap-env <<EOF
HOSTNAME=$(printf '%q' "${HOSTNAME}")
USERNAME=$(printf '%q' "${USERNAME}")
ROOT_PASSWORD=$(printf '%q' "${ROOT_PASSWORD}")
USER_PASSWORD=$(printf '%q' "${USER_PASSWORD}")
LUKS_UUID="${LUKS_UUID}"
ROOT_PART="${ROOT_PART}"
ESP_PART="${ESP_PART}"
BOOT_PART="${BOOT_PART}"
BIOS_PART="${BIOS_PART}"
TARGET_DISK=$(printf '%q' "${TARGET_DISK}")
FIRMWARE_MODE="${FIRMWARE_MODE}"
CPU_UCODE="${CPU_UCODE}"
EOF
    chmod 600 /mnt/root/.bootstrap-env

    # ------------------------- Chroot setup script --------------------------
    log_section "CHROOT CONFIGURATION"

    cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -uo pipefail
trap 'echo "[CHROOT-WARN] error at line $LINENO (continuing)" >&2' ERR

source /root/.bootstrap-env

# Locale & timezone (Europe/Paris, fr_FR + en_US)
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc || true
sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "LC_COLLATE=C"     >> /etc/locale.conf

# Console keymap (AZERTY)
echo "KEYMAP=fr-latin1" > /etc/vconsole.conf

# Hostname & hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
HOSTS

# Pacman tuning + multilib
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm
fi

# Users & sudo
echo "root:${ROOT_PASSWORD}" | chpasswd
useradd -m -G wheel,audio,video,input,storage,optical,network,power,lp -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable systemd-resolved 2>/dev/null || true
systemctl enable vmtoolsd 2>/dev/null || true
systemctl enable vmware-vmblock-fuse 2>/dev/null || true

# mkinitcpio (BTRFS + LUKS + VMware controllers)
cat > /etc/mkinitcpio.conf <<'MKINIT'
MODULES=(btrfs vmw_pvscsi vmw_balloon vmwgfx mptsas mpt3sas mptspi BusLogic ahci nvme xhci_pci sd_mod sr_mod)
BINARIES=(/usr/bin/btrfs)
FILES=()
HOOKS=(base udev microcode autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-3 -T0)
MKINIT
mkinitcpio -P

# Bootloader: dispatch on FIRMWARE_MODE
UCODE_LINE=""
[[ -n "${CPU_UCODE}" ]] && [[ -f "/boot/${CPU_UCODE}.img" ]] && \
    UCODE_LINE="initrd  /${CPU_UCODE}.img"

KERNEL_CMDLINE="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw quiet loglevel=3"

if [[ "${FIRMWARE_MODE}" == "uefi" ]]; then
    # systemd-boot UEFI
    bootctl install --esp-path=/boot
    mkdir -p /boot/EFI/BOOT
    [[ -f /boot/EFI/systemd/systemd-bootx64.efi ]] && \
        cp -f /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI

    mkdir -p /boot/loader/entries
    cat > /boot/loader/loader.conf <<'LOADER'
default      arch.conf
timeout      3
console-mode auto
editor       no
LOADER

    cat > /boot/loader/entries/arch.conf <<ARCHENTRY
title   Arch Linux (VMware)
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux.img
options ${KERNEL_CMDLINE}
ARCHENTRY

    cat > /boot/loader/entries/arch-fallback.conf <<ARCHFB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw loglevel=4
ARCHFB
    sed -i '/^[[:space:]]*$/d' /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf 2>/dev/null || true
else
    # GRUB BIOS Legacy (i386-pc) -- core.img embedded in bios_boot partition,
    # /boot is unencrypted ext4 so GRUB can read kernel/initramfs before
    # the LUKS unlock prompt.
    sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    grep -q "^GRUB_ENABLE_CRYPTODISK" /etc/default/grub || \
        echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${KERNEL_CMDLINE}\"|" /etc/default/grub
    sed -i 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

    grub-install --target=i386-pc --recheck --boot-directory=/boot "${TARGET_DISK}"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# Take ownership of the user's home payload
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/imperative-dots" \
                                  "/home/${USERNAME}/arch-installer.sh"

# One-shot first-login launcher: runs the dotfiles phase the first time
# the user logs in on a TTY (or any login shell). Self-removing block.
BASH_PROFILE="/home/${USERNAME}/.bash_profile"
touch "$BASH_PROFILE"
cat >> "$BASH_PROFILE" <<'PROFHOOK'

# arch-installer:dotfiles-once START
if [ -f "$HOME/arch-installer.sh" ] && [ -d "$HOME/imperative-dots" ] \
   && [ ! -f "$HOME/.cache/arch-installer-dotfiles-done" ]; then
    mkdir -p "$HOME/.cache"
    touch "$HOME/.cache/arch-installer-dotfiles-done"
    echo ""
    echo "==> First login detected. Launching imperative-dots installer."
    echo "    (Press Ctrl+C in the next 5s to skip; you can re-run manually with:"
    echo "       bash ~/arch-installer.sh --phase=dotfiles)"
    sleep 5
    bash "$HOME/arch-installer.sh" --phase=dotfiles
fi
# arch-installer:dotfiles-once END
PROFHOOK
chown "${USERNAME}:${USERNAME}" "$BASH_PROFILE"
chmod 644 "$BASH_PROFILE"

# Persist LUKS header inside the new root for the user
[[ -f /tmp/luks-header.img ]] && cp /tmp/luks-header.img /root/luks-header.img 2>/dev/null && \
    chmod 600 /root/luks-header.img

# Wipe credentials
shred -u /root/.bootstrap-env 2>/dev/null || rm -f /root/.bootstrap-env

echo "[CHROOT] Done."
CHROOT
    chmod +x /mnt/root/chroot-setup.sh

    cp /tmp/luks-header.img /mnt/tmp/luks-header.img 2>/dev/null || true

    log_info "Entering chroot..."
    arch-chroot /mnt /root/chroot-setup.sh
    rm -f /mnt/root/chroot-setup.sh

    # ------------------------------- Done -----------------------------------
    log_section "BOOTSTRAP COMPLETE"
    log_ok "Base Arch installed on ${TARGET_DISK} with LUKS2/Argon2id + BTRFS."
    log_ok "Firmware mode: ${FIRMWARE_MODE} (bootloader: $([[ "$FIRMWARE_MODE" == "uefi" ]] && echo 'systemd-boot' || echo 'GRUB i386-pc'))"
    log_ok "User '${USERNAME}' created. Hostname: ${HOSTNAME}."
    log_warn "LUKS header backup: /tmp/luks-header.img (live) and /root/luks-header.img (target). COPY OFF DISK."
    log_info "Reboot, log in as '${USERNAME}' on TTY -> the dotfiles phase will auto-launch."

    run_post_install_menu
}

###############################################################################
# Final post-install menu (after bootstrap finishes, OR re-entered after a
# chroot dive via "exec arch-installer.sh --phase=postmenu")
###############################################################################
run_post_install_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}  Log file: ${LOG_FILE}${RESET}"
        echo ""
        echo -e "${YELLOW}${BOLD}  INSTALLATION FINISHED. WHAT NOW?${RESET}"
        echo -e "  ${CYAN}[1]${RESET}  Reboot now (unmounts everything cleanly)"
        echo -e "  ${CYAN}[2]${RESET}  Enter the new install via chroot (drop into bash)"
        echo -e "  ${CYAN}[3]${RESET}  Quit the installer (mounts kept open)"
        echo ""
        local final_choice
        read -rp "$(echo -e "${YELLOW}  Your choice [1-3]: ${RESET}")" final_choice

        case "$final_choice" in
            1)
                log_section "UNMOUNT & REBOOT"
                sync
                umount -R /mnt 2>/dev/null || true
                cryptsetup close cryptroot 2>/dev/null || true
                log_info "Rebooting in 3 seconds..."
                sleep 3
                systemctl reboot
                ;;
            2)
                if ! mountpoint -q /mnt 2>/dev/null; then
                    log_warn "/mnt is no longer mounted (you probably already rebooted/quit)."
                    log_warn "Cannot drop into chroot."
                    sleep 2
                    continue
                fi
                log_info "Entering chroot... (type 'exit' to come back to this menu)"
                arch-chroot /mnt /usr/bin/bash || true
                # Re-launch JUST the menu (avoid re-running the whole bootstrap = repartition!)
                exec "$SCRIPT_PATH" --phase=postmenu
                ;;
            3)
                log_section "QUITTING"
                log_warn "Mounts on /mnt are kept open. Run:"
                log_warn "  umount -R /mnt && cryptsetup close cryptroot"
                log_warn "before pulling out the install media."
                exit 0
                ;;
            *)
                log_warn "Invalid choice."
                ;;
        esac
    done
}

###############################################################################
# Dispatch
###############################################################################
case "$PHASE" in
    bootstrap) run_bootstrap_phase "$@" ;;
    dotfiles)  run_dotfiles_phase  "$@" ;;
    postmenu)  run_post_install_menu     ;;
    *)         die "Unknown phase: $PHASE" ;;
esac
