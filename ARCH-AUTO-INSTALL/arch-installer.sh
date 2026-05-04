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
#   --phase=bootstrap | --phase=dotfiles | --phase=auto (default)
# -----------------------------------------------------------------------------
PHASE="auto"
for arg in "$@"; do
    case "$arg" in
        --phase=bootstrap) PHASE="bootstrap" ;;
        --phase=dotfiles)  PHASE="dotfiles"  ;;
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

    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        die "UEFI not detected. Boot the VM with EFI firmware (.vmx: firmware = \"efi\")."
    fi
    log_ok "Firmware: UEFI confirmed"

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

    # ----------------------------- User inputs ------------------------------
    log_section "USER INPUTS"

    echo -e "${WHITE}Available disks:${RESET}\n"
    lsblk -d -e7 -o NAME,SIZE,MODEL,TYPE | grep -E 'disk' | tee -a "$LOG_FILE"
    echo ""

    local DEFAULT_DISK="/dev/sda" TARGET_DISK CONFIRM_WIPE
    [[ -b /dev/nvme0n1 ]] && DEFAULT_DISK="/dev/nvme0n1"
    read -rp "$(echo -e "${YELLOW}> Target disk to ERASE [${DEFAULT_DISK}]: ${RESET}")" TARGET_DISK
    TARGET_DISK="${TARGET_DISK:-$DEFAULT_DISK}"
    [[ -b "$TARGET_DISK" ]] || die "Disk ${TARGET_DISK} not found."

    echo ""
    echo -e "${RED}${BOLD}!! ${TARGET_DISK} WILL BE COMPLETELY WIPED !!${RESET}"
    read -rp "$(echo -e "${YELLOW}> Type 'WIPE' to confirm: ${RESET}")" CONFIRM_WIPE
    [[ "$CONFIRM_WIPE" == "WIPE" ]] || die "Aborted by user."

    local HOSTNAME USERNAME
    read -rp "$(echo -e "${YELLOW}> Hostname [archvm]: ${RESET}")" HOSTNAME
    HOSTNAME="${HOSTNAME:-archvm}"

    read -rp "$(echo -e "${YELLOW}> Username [user]: ${RESET}")" USERNAME
    USERNAME="${USERNAME:-user}"
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username (POSIX rules)."

    prompt_passphrase() {
        local label="$1" min="$2" p1 p2
        while true; do
            read -srp "$(echo -e "${YELLOW}> ${label}: ${RESET}")" p1; echo ""
            read -srp "$(echo -e "${YELLOW}> Confirm ${label}: ${RESET}")" p2; echo ""
            [[ "$p1" == "$p2" ]] || { log_warn "Mismatch."; continue; }
            (( ${#p1} >= min )) || { log_warn "Too short (>=${min} chars)."; continue; }
            printf '%s' "$p1"; return 0
        done
    }

    local LUKS_PASSPHRASE ROOT_PASSWORD USER_PASSWORD
    LUKS_PASSPHRASE="$(prompt_passphrase 'LUKS passphrase (>=12 chars)' 12)"
    ROOT_PASSWORD="$(prompt_passphrase 'root password (>=8 chars)' 8)"
    USER_PASSWORD="$(prompt_passphrase "${USERNAME} password (>=8 chars)" 8)"

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

    log_info "Creating GPT layout (ESP 512MB FAT32 + LUKS root)..."
    sgdisk -o \
           -n 1:0:+512M -t 1:ef00 -c 1:"EFI" \
           -n 2:0:0     -t 2:8309 -c 2:"CRYPTROOT" \
           "${TARGET_DISK}"

    sync
    partprobe "${TARGET_DISK}" 2>/dev/null || true
    udevadm settle --timeout=15 2>/dev/null || sleep 3

    local SUFFIX="" ESP_PART ROOT_PART
    [[ "${TARGET_DISK}" =~ [0-9]$ ]] && SUFFIX="p"
    ESP_PART="${TARGET_DISK}${SUFFIX}1"
    ROOT_PART="${TARGET_DISK}${SUFFIX}2"
    [[ -b "$ESP_PART"  ]] || die "ESP partition ${ESP_PART} missing."
    [[ -b "$ROOT_PART" ]] || die "Root partition ${ROOT_PART} missing."

    log_info "Formatting ESP (FAT32) on ${ESP_PART}..."
    mkfs.fat -F 32 -n EFI "${ESP_PART}" >/dev/null

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
    mount "${ESP_PART}" /mnt/boot

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

UCODE_LINE=""
[[ -n "${CPU_UCODE}" ]] && [[ -f "/boot/${CPU_UCODE}.img" ]] && \
    UCODE_LINE="initrd  /${CPU_UCODE}.img"

cat > /boot/loader/entries/arch.conf <<ARCHENTRY
title   Arch Linux (VMware)
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux.img
options cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw quiet loglevel=3
ARCHENTRY

cat > /boot/loader/entries/arch-fallback.conf <<ARCHFB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw loglevel=4
ARCHFB
sed -i '/^[[:space:]]*$/d' /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf 2>/dev/null || true

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
    log_ok "User '${USERNAME}' created. Hostname: ${HOSTNAME}."
    log_warn "LUKS header backup: /tmp/luks-header.img (live) and /root/luks-header.img (target). COPY OFF DISK."
    log_info "Reboot, log in as '${USERNAME}' on TTY -> the dotfiles phase will auto-launch."

    local R
    read -rp "$(echo -e "${YELLOW}> Unmount and reboot now? [y/N]: ${RESET}")" R
    if [[ "$R" =~ ^[Yy]$ ]]; then
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        log_info "Rebooting..."
        sleep 2
        systemctl reboot
    fi
}

###############################################################################
# Dispatch
###############################################################################
case "$PHASE" in
    bootstrap) run_bootstrap_phase "$@" ;;
    dotfiles)  run_dotfiles_phase  "$@" ;;
    *)         die "Unknown phase: $PHASE" ;;
esac
