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

# Persistent User-Agent applied to: live ISO (curl/wget config), the installed
# system (curl/wget/env/Firefox policy/Chromium flags). Spoofs an Edge-on-Win10
# fingerprint -- canonical syntax (semicolons everywhere) so JS detectors that
# check UA shape don't immediately flag it.
readonly CUSTOM_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.5790.170 Safari/537.36 Edg/115.0.1901.183'

# Companion fields the UA implies. Used for Firefox JS overrides so navigator.*
# stays internally consistent.
readonly CUSTOM_UA_PLATFORM='Win32'
readonly CUSTOM_UA_OSCPU='Windows NT 10.0; Win64; x64'
readonly CUSTOM_UA_APPVERSION='5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.5790.170 Safari/537.36 Edg/115.0.1901.183'
readonly CUSTOM_UA_BUILDID='20181001000000'
readonly CUSTOM_ACCEPT_LANG='en-US,en;q=0.9'

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

# log_* helpers MUST always return 0 -- otherwise a tee/disk hiccup propagates
# through `cmd || log_warn ...` chains and `set -e` kills the install for
# nothing.
log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*" | tee -a "$LOG_FILE" || true; return 0; }
log_ok()      { echo -e "${GREEN}[ OK ]${RESET}   $*" | tee -a "$LOG_FILE" || true; return 0; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}   $*" | tee -a "$LOG_FILE" || true; return 0; }
log_error()   { echo -e "${RED}[ERR ]${RESET}   $*" | tee -a "$LOG_FILE" || true; return 0; }
log_section() {
    {
        echo -e "\n${MAGENTA}${BOLD}--------------------------------------------------------${RESET}"
        echo -e "${MAGENTA}${BOLD}  $*${RESET}"
        echo -e "${MAGENTA}${BOLD}--------------------------------------------------------${RESET}\n"
    } | tee -a "$LOG_FILE" || true
    return 0
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

# Curated OUI vendor database (Technitium MAC Address Changer-style). Format
# per entry: "VENDOR:TYPE:OUI" where TYPE in {ether, wifi, bt} and OUI is the
# 3-byte assignment (uppercase, colon-separated).  This is a hand-picked subset
# of real, public IEEE OUIs from common consumer NIC vendors -- enough that an
# auto-generated MAC looks coherent (Intel WiFi card, Realtek Ethernet, CSR
# Bluetooth controller, etc.) instead of a flat random string.
declare -ra OUI_DB=(
    # Ethernet
    "Intel:ether:00:1B:21"        "Intel:ether:00:1F:3B"        "Intel:ether:00:24:D7"
    "Intel:ether:3C:97:0E"        "Intel:ether:8C:8C:AA"        "Intel:ether:A4:4C:C8"
    "Realtek:ether:00:E0:4C"      "Realtek:ether:52:54:00"      "Realtek:ether:00:14:78"
    "Realtek:ether:00:13:33"      "Realtek:ether:1C:6F:65"
    "Broadcom:ether:00:10:18"     "Broadcom:ether:00:1A:E3"     "Broadcom:ether:B8:8D:12"
    "Marvell:ether:00:50:43"      "Marvell:ether:00:21:55"
    "Aquantia:ether:00:17:B6"     "Killer:ether:00:24:1D"
    "Atheros:ether:00:03:7F"      "VMware:ether:00:50:56"
    # WiFi
    "Intel:wifi:00:13:02"         "Intel:wifi:00:13:E8"         "Intel:wifi:00:1B:77"
    "Intel:wifi:24:77:03"         "Intel:wifi:7C:7A:91"         "Intel:wifi:F8:34:41"
    "Qualcomm:wifi:00:03:7F"      "Qualcomm:wifi:04:F0:21"      "Qualcomm:wifi:00:13:74"
    "Qualcomm:wifi:88:DE:7C"      "Qualcomm:wifi:1C:99:4C"
    "Realtek:wifi:00:E0:4C"       "Realtek:wifi:14:CC:20"       "Realtek:wifi:00:1F:1F"
    "Realtek:wifi:E8:4E:06"
    "MediaTek:wifi:00:0C:43"      "MediaTek:wifi:14:F6:5A"      "MediaTek:wifi:34:6B:46"
    "Broadcom:wifi:00:10:18"      "Broadcom:wifi:00:1B:B1"      "Broadcom:wifi:5C:F9:38"
    "Apple:wifi:28:CF:E9"         "Apple:wifi:70:CD:60"
    # Bluetooth
    "CSR:bt:00:02:5B"             "CSR:bt:00:1B:DC"
    "Apple:bt:00:23:6C"           "Apple:bt:90:84:0D"           "Apple:bt:F0:DC:E2"
    "Broadcom:bt:00:0A:F5"        "Broadcom:bt:00:90:4B"        "Broadcom:bt:F8:F1:B6"
    "Intel:bt:00:14:6C"           "Intel:bt:8C:DC:D4"
    "Qualcomm:bt:00:78:88"        "Qualcomm:bt:1C:99:4C"
    "Cypress:bt:00:A0:50"         "Realtek:bt:E8:4E:06"
)

# Generate a locally-administered unicast MAC (no vendor coherence).
# First octet has bit 1 set + bit 0 cleared (second hex char in {2,6,A,E}).
gen_random_mac() {
    local n first
    n=$(( RANDOM % 64 ))
    printf -v first "%02x" $(( n * 4 + 2 ))
    local mac="$first" hex i
    for i in 1 2 3 4 5; do
        printf -v hex "%02x" $(( RANDOM % 256 ))
        mac+=":$hex"
    done
    printf '%s' "$mac"
}

# Pick a random OUI matching the requested device type and emit "vendor|mac".
# TYPE in {ether, wifi, bt}. Falls back to gen_random_mac if no OUI matches.
gen_vendor_mac() {
    local type="$1"
    local matches=() entry
    for entry in "${OUI_DB[@]}"; do
        [[ "$entry" == *":$type:"* ]] && matches+=("$entry")
    done
    if [[ ${#matches[@]} -eq 0 ]]; then
        printf 'Random|%s' "$(gen_random_mac)"
        return
    fi
    local pick="${matches[RANDOM % ${#matches[@]}]}"
    local vendor="${pick%%:*}"
    local oui="${pick#*:$type:}"
    local mac="${oui,,}" hex i
    for i in 1 2 3; do
        printf -v hex "%02x" $(( RANDOM % 256 ))
        mac+=":$hex"
    done
    printf '%s|%s' "$vendor" "$mac"
}

# Validate a user-supplied MAC. Accepts aa:bb:cc:dd:ee:ff (any case).
# Rejects multicast (LSB of first octet set) and the broadcast MAC.
validate_mac() {
    local m="${1,,}"
    if ! [[ "$m" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]]; then
        log_warn "Invalid MAC format (expected aa:bb:cc:dd:ee:ff)."
        return 1
    fi
    local first_oct="${m:0:2}"
    if (( 0x$first_oct & 0x01 )); then
        log_warn "Multicast MAC refused (LSB of first octet is 1)."
        return 1
    fi
    if [[ "$m" == "ff:ff:ff:ff:ff:ff" ]] || [[ "$m" == "00:00:00:00:00:00" ]]; then
        log_warn "Broadcast or null MAC refused."
        return 1
    fi
    return 0
}

# Generate a random Linux interface name. 8 chars: starts with a letter,
# rest alphanumeric (lowercase). Well under the 15-char IFNAMSIZ limit.
gen_random_iface_name() {
    local letters="abcdefghijklmnopqrstuvwxyz"
    local alnum="abcdefghijklmnopqrstuvwxyz0123456789"
    local name="${letters:RANDOM%26:1}"
    local i
    for i in 1 2 3 4 5 6 7; do
        name+="${alnum:RANDOM%36:1}"
    done
    printf '%s' "$name"
}

# Randomize the live ISO network identity BEFORE we touch the network. Covers
# Ethernet (always, used for pacstrap/reflector), WiFi (if a wlan iface exists,
# best-effort -- many WiFi firmwares refuse runtime MAC changes), and Bluetooth
# (skipped in the live env: BT controller often not initialised on the ISO and
# bluez-utils is not always present).
randomize_live_network() {
    local stop_svc
    for stop_svc in systemd-networkd dhcpcd NetworkManager wpa_supplicant; do
        systemctl stop "$stop_svc" 2>/dev/null || true
    done
    pkill -f "dhcpcd|dhclient|wpa_supplicant" 2>/dev/null || true
    sleep 1

    # ---- Ethernet ----
    local eth_iface
    eth_iface="$(ip -o link show 2>/dev/null \
        | awk -F': ' '/link\/ether/ && $2 !~ /^(wl|lo)/ {print $2; exit}')"
    if [[ -n "$eth_iface" ]]; then
        local r vendor mac new_iface
        r="$(gen_vendor_mac ether)"
        vendor="${r%|*}"; mac="${r#*|}"
        new_iface="$(gen_random_iface_name)"
        log_info "Live ETH randomization: ${eth_iface} -> ${new_iface} (vendor=${vendor}, MAC=${mac})"
        ip link set "$eth_iface" down 2>/dev/null || log_warn "Cannot down ${eth_iface}."
        ip link set "$eth_iface" address "$mac" 2>/dev/null \
            || log_warn "Cannot set MAC on ${eth_iface} (driver may forbid it)."
        ip link set "$eth_iface" name "$new_iface" 2>/dev/null \
            || { log_warn "Cannot rename ${eth_iface} -> ${new_iface}; keeping original."; new_iface="$eth_iface"; }
        ip link set "$new_iface" up 2>/dev/null || true
    else
        log_warn "No ethernet iface found; skipping ETH live randomization."
    fi

    # ---- WiFi (best-effort: most wifi drivers/firmware refuse ip link MAC change) ----
    local wifi_iface
    wifi_iface="$(ip -o link show 2>/dev/null \
        | awk -F': ' '/link\/ether/ && $2 ~ /^wl/ {print $2; exit}')"
    if [[ -n "$wifi_iface" ]] && command -v ip &>/dev/null; then
        local r vendor mac
        r="$(gen_vendor_mac wifi)"
        vendor="${r%|*}"; mac="${r#*|}"
        log_info "Live WIFI randomization attempt on ${wifi_iface} (vendor=${vendor}, MAC=${mac})"
        ip link set "$wifi_iface" down 2>/dev/null || true
        if ip link set "$wifi_iface" address "$mac" 2>/dev/null; then
            log_ok "WiFi MAC changed on ${wifi_iface}."
        else
            log_warn "WiFi MAC change refused by driver/firmware on ${wifi_iface} -- skipped."
        fi
        ip link set "$wifi_iface" up 2>/dev/null || true
    fi

    # ---- Restart DHCP on whichever iface we have ----
    if systemctl start systemd-networkd 2>/dev/null; then
        :
    elif [[ -n "${eth_iface:-}" ]]; then
        dhcpcd -b "${new_iface:-$eth_iface}" 2>/dev/null || true
    fi

    # Wait up to 15s for an IPv4 lease on either iface
    local i=0 target="${new_iface:-${eth_iface:-${wifi_iface:-}}}"
    [[ -z "$target" ]] && return 0
    while (( i < 15 )); do
        if ip -4 addr show "$target" 2>/dev/null | grep -q 'inet '; then
            log_ok "DHCP lease acquired on ${target}."
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    log_warn "No DHCP lease on ${target} after 15s; subsequent network checks may fail."
    return 0
}

# Write system-wide curl + wget User-Agent + Accept-Language overrides under
# the given root (use "" for the live ISO, "/mnt" for the new install).
# Coherent header set: a real Edge-on-Win10 install sends both these headers.
apply_user_agent() {
    local root="$1"
    install -d -m 755 "${root}/etc"
    cat > "${root}/etc/curlrc" <<EOF
# Persistent fingerprint headers (arch-installer)
user-agent = "${CUSTOM_UA}"
header = "Accept-Language: ${CUSTOM_ACCEPT_LANG}"
EOF
    chmod 644 "${root}/etc/curlrc"
    # /etc/wgetrc may already exist with comments; prepend our overrides
    {
        echo "# Persistent fingerprint headers (arch-installer)"
        echo "user_agent = ${CUSTOM_UA}"
        echo "header = Accept-Language: ${CUSTOM_ACCEPT_LANG}"
        echo ""
        if [[ -f "${root}/etc/wgetrc" ]]; then
            cat "${root}/etc/wgetrc"
        fi
    } > "${root}/etc/wgetrc.new"
    mv "${root}/etc/wgetrc.new" "${root}/etc/wgetrc"
    chmod 644 "${root}/etc/wgetrc"
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
    case "$VM_TYPE" in
        vmware)            log_ok "VMware guest detected" ;;
        kvm)               log_ok "KVM guest detected (also covers Proxmox VMs)" ;;
        qemu)              log_ok "QEMU guest detected" ;;
        oracle)            log_ok "VirtualBox guest detected" ;;
        microsoft)         log_ok "Hyper-V guest detected" ;;
        none|"")           log_ok "Bare-metal install"; VM_TYPE="none" ;;
        *)                 log_warn "Unknown virtualization '${VM_TYPE}'; treated as generic VM" ;;
    esac

    # Locate the bundled imperative-dots/ folder
    local DOTS_SRC="$SCRIPT_DIR/imperative-dots"
    [[ -d "$DOTS_SRC" ]] || die "Bundled folder not found: $DOTS_SRC (must sit next to this script)."
    [[ -f "$DOTS_SRC/install.sh" ]] || die "$DOTS_SRC/install.sh missing."

    # ------------------------------ Pre-flight ------------------------------
    log_section "PRE-FLIGHT"

    # Randomize live ethernet identity (MAC + iface name) BEFORE any outbound
    # connection. So pacman/keyring/reflector are reached with a freshly-rolled
    # MAC and interface name, never the original. Best-effort.
    randomize_live_network

    # Pin User-Agent on the live ISO too, so any curl/wget call from this
    # script (or sub-tools that respect curlrc/wgetrc) sends the spoofed UA.
    log_info "Applying persistent User-Agent on live ISO..."
    apply_user_agent ""
    export HTTP_USER_AGENT="${CUSTOM_UA}"
    export USER_AGENT="${CUSTOM_UA}"

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

    # awk is pipefail-safe (returns 0 even if no match), unlike grep|awk
    CPU_VENDOR="$(awk '/^vendor_id/{print $3; exit}' /proc/cpuinfo 2>/dev/null || echo Unknown)"
    [[ -z "$CPU_VENDOR" ]] && CPU_VENDOR="Unknown"
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
        i=$((i + 1))
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
    local ETH_MAC="" ETH_VENDOR="" ETH_IFNAME=""
    local WIFI_MAC="" WIFI_VENDOR="" WIFI_IFNAME=""
    local BT_MAC=""  BT_VENDOR=""

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

    # MAC addresses for the INSTALLED system (separate from the live ISO
    # randomization above). For each of ETH / WIFI / BT, ask whether to pin a
    # specific MAC; otherwise generate one matching a real vendor OUI from the
    # embedded database (Technitium-style coherence). For ETH and WIFI an empty
    # answer ALSO renames the interface to a random alphanumeric label so the
    # device's identity is fully synthetic.
    echo -e "  ${DIM}(For each radio type below, press Enter to auto-generate"
    echo -e "   a vendor-coherent MAC (Intel/Realtek/Qualcomm/Broadcom/...) and,"
    echo -e "   for ETH/WIFI, a random network interface name.)${RESET}"
    echo ""

    # ---- Ethernet ----
    local want_mac
    read -rp "$(echo -e "${YELLOW}> ETHERNET: pin a custom MAC? [y/N]: ${RESET}")" want_mac
    if [[ "$want_mac" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "$(echo -e "${YELLOW}>   MAC (aa:bb:cc:dd:ee:ff): ${RESET}")" ETH_MAC
            ETH_MAC="${ETH_MAC,,}"
            if validate_mac "$ETH_MAC"; then
                ETH_VENDOR="custom"
                ETH_IFNAME=""
                echo -e "  ${GREEN}>   ETH MAC: ${BOLD}${ETH_MAC}${RESET}  (iface name unchanged)"
                break
            fi
        done
    else
        local r="$(gen_vendor_mac ether)"
        ETH_VENDOR="${r%|*}"; ETH_MAC="${r#*|}"
        ETH_IFNAME="$(gen_random_iface_name)"
        echo -e "  ${GREEN}>   ETH MAC: ${BOLD}${ETH_MAC}${RESET}  (vendor: ${BOLD}${ETH_VENDOR}${RESET})"
        echo -e "  ${GREEN}>   ETH iface: ${BOLD}${ETH_IFNAME}${RESET}"
    fi

    # ---- WiFi ----
    read -rp "$(echo -e "${YELLOW}> WIFI: pin a custom MAC? [y/N]: ${RESET}")" want_mac
    if [[ "$want_mac" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "$(echo -e "${YELLOW}>   MAC (aa:bb:cc:dd:ee:ff): ${RESET}")" WIFI_MAC
            WIFI_MAC="${WIFI_MAC,,}"
            if validate_mac "$WIFI_MAC"; then
                WIFI_VENDOR="custom"
                WIFI_IFNAME=""
                echo -e "  ${GREEN}>   WIFI MAC: ${BOLD}${WIFI_MAC}${RESET}  (iface name unchanged)"
                break
            fi
        done
    else
        local r="$(gen_vendor_mac wifi)"
        WIFI_VENDOR="${r%|*}"; WIFI_MAC="${r#*|}"
        WIFI_IFNAME="$(gen_random_iface_name)"
        echo -e "  ${GREEN}>   WIFI MAC: ${BOLD}${WIFI_MAC}${RESET}  (vendor: ${BOLD}${WIFI_VENDOR}${RESET})"
        echo -e "  ${GREEN}>   WIFI iface: ${BOLD}${WIFI_IFNAME}${RESET}"
    fi

    # ---- Bluetooth ----
    read -rp "$(echo -e "${YELLOW}> BLUETOOTH: pin a custom MAC? [y/N]: ${RESET}")" want_mac
    if [[ "$want_mac" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "$(echo -e "${YELLOW}>   MAC (aa:bb:cc:dd:ee:ff): ${RESET}")" BT_MAC
            BT_MAC="${BT_MAC,,}"
            if validate_mac "$BT_MAC"; then
                BT_VENDOR="custom"
                echo -e "  ${GREEN}>   BT MAC: ${BOLD}${BT_MAC}${RESET}"
                break
            fi
        done
    else
        local r="$(gen_vendor_mac bt)"
        BT_VENDOR="${r%|*}"; BT_MAC="${r#*|}"
        echo -e "  ${GREEN}>   BT MAC: ${BOLD}${BT_MAC}${RESET}  (vendor: ${BOLD}${BT_VENDOR}${RESET})"
    fi
    echo ""

    # ------------------------ Summary + confirm WIPE ------------------------
    log_section "INSTALL SUMMARY"
    echo -e "  ${WHITE}Target disk     :${RESET}  ${BOLD}${TARGET_DISK}${RESET}"
    echo -e "  ${WHITE}Firmware mode   :${RESET}  ${BOLD}${FIRMWARE_MODE}${RESET}  ($([[ "$FIRMWARE_MODE" == "uefi" ]] && echo systemd-boot || echo 'GRUB i386-pc'))"
    echo -e "  ${WHITE}Username        :${RESET}  ${BOLD}${USERNAME}${RESET}"
    echo -e "  ${WHITE}Hostname        :${RESET}  ${BOLD}${HOSTNAME}${RESET}"
    echo -e "  ${WHITE}ETH MAC         :${RESET}  ${BOLD}${ETH_MAC}${RESET}  (${ETH_VENDOR})"
    echo -e "  ${WHITE}ETH iface       :${RESET}  ${BOLD}${ETH_IFNAME:-<keep default>}${RESET}"
    echo -e "  ${WHITE}WIFI MAC        :${RESET}  ${BOLD}${WIFI_MAC}${RESET}  (${WIFI_VENDOR})"
    echo -e "  ${WHITE}WIFI iface      :${RESET}  ${BOLD}${WIFI_IFNAME:-<keep default>}${RESET}"
    echo -e "  ${WHITE}BT  MAC         :${RESET}  ${BOLD}${BT_MAC}${RESET}  (${BT_VENDOR})"
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
    LUKS_UUID="$(blkid -s UUID -o value "${ROOT_PART}" 2>/dev/null || true)"
    [[ -n "$LUKS_UUID" ]] || die "Could not read LUKS UUID from ${ROOT_PART} -- aborting."
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
        # Guest agents for the supported hypervisors. Installing all of them
        # is harmless on baremetal (services stay disabled) but ensures the
        # same image works on VMware, KVM/QEMU/Proxmox, and Hyper-V.
        # - open-vm-tools : vmtoolsd for VMware (timeSync + resolutionSet)
        # - qemu-guest-agent : KVM/QEMU/Proxmox host can shutdown/freeze cleanly
        # - spice-vdagent : SPICE console clipboard + auto-resize (Proxmox web,
        #                   virt-manager, Boxes)
        # - hyperv : Hyper-V Integration Services (in 'extra')
        # gtk3 = soft dep of open-vm-tools GUI helpers.
        open-vm-tools gtk3
        qemu-guest-agent spice-vdagent
        hyperv
        # Wireless + Bluetooth stacks (needed by our randomization persistence:
        # `iw` for WiFi MAC ops, `bluez-utils` ships `btmgmt` to set BT MAC).
        iw wireless_tools wpa_supplicant
        bluez bluez-utils
        # Font stack for browser-fingerprint coherence -- fingerprinters often
        # enumerate fonts via JS. Closest set to Windows we can ship from
        # official repos without AUR (real Segoe UI requires AUR/manual).
        ttf-liberation ttf-dejavu
        noto-fonts noto-fonts-emoji noto-fonts-cjk
        cantarell-fonts ttf-bitstream-vera
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
ETH_MAC="${ETH_MAC}"
ETH_IFNAME="${ETH_IFNAME}"
ETH_VENDOR="${ETH_VENDOR}"
WIFI_MAC="${WIFI_MAC}"
WIFI_IFNAME="${WIFI_IFNAME}"
WIFI_VENDOR="${WIFI_VENDOR}"
BT_MAC="${BT_MAC}"
BT_VENDOR="${BT_VENDOR}"
CUSTOM_UA=$(printf '%q' "${CUSTOM_UA}")
VM_TYPE="${VM_TYPE}"
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
# Guest-agent services: enable only the one matching the detected hypervisor.
# All packages are installed unconditionally (so the image is portable across
# baremetal/VMware/KVM/Proxmox/Hyper-V), but only the relevant service runs.
# vmware-vmblock-fuse (FUSE backing for HGFS drag&drop) is always disabled --
# we never want host<->guest file leakage even on VMware.
systemctl disable vmware-vmblock-fuse 2>/dev/null || true
systemctl mask    vmware-vmblock-fuse 2>/dev/null || true

case "${VM_TYPE:-none}" in
    vmware)
        systemctl enable vmtoolsd 2>/dev/null || true
        ;;
    kvm|qemu)
        systemctl enable qemu-guest-agent 2>/dev/null || true
        # spice-vdagentd uses systemd user-session activation by default,
        # so no system-wide enable is needed. The d-bus-activated user
        # service starts on first SPICE connection.
        ;;
    oracle)
        # VirtualBox: nothing to enable for our minimal config (vboxguest
        # autoload via initramfs MODULES is enough for resize/clipboard).
        :
        ;;
    microsoft)
        systemctl enable hv_kvp_daemon 2>/dev/null || true
        systemctl enable hv_vss_daemon 2>/dev/null || true
        systemctl enable hv_fcopy_daemon 2>/dev/null || true
        ;;
    none|"")
        # baremetal: leave all guest agents disabled
        :
        ;;
esac

# === Minimal vmtoolsd profile: keep ONLY auto-resize + vCenter time sync ===
# Only meaningful on VMware; on other hypervisors vmtoolsd is disabled and
# this file is just dormant config.
# Every other plugin (guestInfo, appInfo, serviceDiscovery, hgfs, unity,
# copyPaste, dnd, vmbackup, gueststats, guestStore) is disabled so the host
# hypervisor can't pull info about us through the back-channel.
mkdir -p /etc/vmware-tools
cat > /etc/vmware-tools/tools.conf <<'TOOLSCONF'
# arch-installer: lock vmtoolsd to a minimal surface
# KEPT: timeSync (vCenter clock sync) + resolutionSet (auto window resize)
# CUT:  every information-exposing or integration plugin

[guestinfo]
disabled = true
poll-interval = 0

[appInfo]
disabled = true
poll-interval = 0

[serviceDiscovery]
disabled = true
poll-interval = 0

[gueststats]
disabled = true
poll-interval = 0

[hgfsServer]
disabled = true

[guestStore]
disabled = true

[unity]
disabled = true

[copyPaste]
disabled = true

[dnd]
disabled = true

[deployPkg]
enable-customization = false

[vmbackup]
disabled = true
enableSyncDriver = false

[powerops]
# leave enabled: lets vCenter cleanly shut down / reboot the VM
disabled = false

# [timeSync]      -- KEPT (default-enabled)
# [resolutionSet] -- KEPT (default-enabled)
TOOLSCONF
chmod 644 /etc/vmware-tools/tools.conf
systemctl enable bluetooth 2>/dev/null || true

# === Persistent ETH identity (MAC + optional iface rename) ===
# systemd .link files are consumed by udev BEFORE NetworkManager starts, so
# the chosen MAC/name is in place ahead of any DHCP request.
mkdir -p /etc/systemd/network
{
    echo "[Match]"
    echo "OriginalName=en* eth*"
    echo ""
    echo "[Link]"
    echo "MACAddress=${ETH_MAC}"
    [[ -n "${ETH_IFNAME}" ]] && echo "Name=${ETH_IFNAME}"
    echo "MACAddressPolicy="
    echo "NamePolicy="
} > /etc/systemd/network/10-custom-ether.link
chmod 644 /etc/systemd/network/10-custom-ether.link

# === Persistent WIFI identity ===
# WARNING: many WiFi drivers/firmwares refuse runtime MAC changes; in that
# case the .link directive is silently ignored and the original MAC stays.
# We still write the file -- it's a no-op when unsupported.
{
    echo "[Match]"
    echo "OriginalName=wl*"
    echo ""
    echo "[Link]"
    echo "MACAddress=${WIFI_MAC}"
    [[ -n "${WIFI_IFNAME}" ]] && echo "Name=${WIFI_IFNAME}"
    echo "MACAddressPolicy="
    echo "NamePolicy="
} > /etc/systemd/network/11-custom-wifi.link
chmod 644 /etc/systemd/network/11-custom-wifi.link

# Belt-and-suspenders for NetworkManager: pin our MAC, never randomize.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-no-mac-randomize.conf <<NMCONF
[device]
wifi.scan-rand-mac-address=no

[connection]
ethernet.cloned-mac-address=${ETH_MAC}
wifi.cloned-mac-address=${WIFI_MAC}
NMCONF

# === Persistent BLUETOOTH identity ===
# Bluetooth MAC isn't writable via udev -- it must be set after the controller
# is up, via btmgmt. Some chipsets reject the change (Intel non-vPro, certain
# Realtek revs); the service exits 0 either way to not block boot.
cat > /etc/systemd/system/bt-setmac.service <<'BTSVC'
[Unit]
Description=Pin Bluetooth controller MAC address
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/sleep 2
ExecStart=/usr/local/sbin/bt-setmac

[Install]
WantedBy=multi-user.target
BTSVC

cat > /usr/local/sbin/bt-setmac <<BTSCRIPT
#!/usr/bin/env bash
# Set the controller MAC for hci0 (the only adapter in a typical VM/laptop).
# Best-effort: many controllers refuse, in which case we just log and exit 0.
TARGET="${BT_MAC}"
if ! command -v btmgmt >/dev/null 2>&1; then
    echo "bt-setmac: btmgmt not present, skipping." >&2
    exit 0
fi
if ! /usr/bin/btmgmt --index 0 info 2>/dev/null | grep -q 'addr'; then
    echo "bt-setmac: no hci0 controller, skipping." >&2
    exit 0
fi
/usr/bin/btmgmt --index 0 power off >/dev/null 2>&1 || true
if /usr/bin/btmgmt --index 0 public-addr "\${TARGET}" >/dev/null 2>&1; then
    echo "bt-setmac: hci0 -> \${TARGET}"
else
    echo "bt-setmac: controller refused MAC change (firmware lock)." >&2
fi
/usr/bin/btmgmt --index 0 power on >/dev/null 2>&1 || true
exit 0
BTSCRIPT
chmod 755 /usr/local/sbin/bt-setmac
systemctl enable bt-setmac.service 2>/dev/null || true

# === Persistent User-Agent + browser fingerprint hardening ===
# Spoof an Edge-on-Win10 UA at every layer we can reach AND apply a coherent
# anti-fingerprinting profile (canvas/WebGL/WebRTC/locale/telemetry knobs).
# Pacman's libcurl ignores curlrc and has no UA knob -- it stays "pacman/<ver>".
mkdir -p /etc/skel/.config

# 1) System-wide curl + wget config (UA + Accept-Language headers)
cat > /etc/curlrc <<UACURL
# Persistent fingerprint headers (arch-installer)
user-agent = "${CUSTOM_UA}"
header = "Accept-Language: ${CUSTOM_ACCEPT_LANG}"
UACURL
chmod 644 /etc/curlrc

{
    echo "# Persistent fingerprint headers (arch-installer)"
    echo "user_agent = ${CUSTOM_UA}"
    echo "header = Accept-Language: ${CUSTOM_ACCEPT_LANG}"
    echo ""
    [[ -f /etc/wgetrc.orig ]] || cp /etc/wgetrc /etc/wgetrc.orig 2>/dev/null || true
    [[ -f /etc/wgetrc.orig ]] && cat /etc/wgetrc.orig
} > /etc/wgetrc.new
mv /etc/wgetrc.new /etc/wgetrc
chmod 644 /etc/wgetrc

# 2) Per-user copies (created user + skel for future users)
for target in "/home/${USERNAME}" /etc/skel; do
    install -d -m 755 "$target"
    cat > "$target/.curlrc" <<UAUC
user-agent = "${CUSTOM_UA}"
header = "Accept-Language: ${CUSTOM_ACCEPT_LANG}"
UAUC
    cat > "$target/.wgetrc" <<UAUW
user_agent = ${CUSTOM_UA}
header = Accept-Language: ${CUSTOM_ACCEPT_LANG}
UAUW
done
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.curlrc" "/home/${USERNAME}/.wgetrc"

# 3) Shell env vars for tools that read HTTP_USER_AGENT / USER_AGENT
cat > /etc/profile.d/00-user-agent.sh <<UAENV
# Persistent User-Agent for shell scripts (arch-installer)
export HTTP_USER_AGENT="${CUSTOM_UA}"
export USER_AGENT="${CUSTOM_UA}"
UAENV
chmod 644 /etc/profile.d/00-user-agent.sh

# 4) Firefox enterprise policy: spoof UA + navigator.* + harden against
# canvas/WebGL/WebRTC/font/timing/telemetry fingerprinting. NOTE:
# privacy.resistFingerprinting (RFP) is NOT enabled because it would override
# our spoofed UA back to a generic Firefox/Win profile. Instead we use
# privacy.fingerprintingProtection (newer, lighter, doesn't touch UA) plus
# individual hardening prefs.
mkdir -p /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<UAFF
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableFirefoxAccounts": true,
    "DisableFormHistory": true,
    "DontCheckDefaultBrowser": true,
    "OfferToSaveLogins": false,
    "PasswordManagerEnabled": false,
    "NetworkPrediction": false,
    "SearchSuggestEnabled": false,
    "EnableTrackingProtection": {
      "Value": true,
      "Locked": true,
      "Cryptomining": true,
      "Fingerprinting": true,
      "EmailTracking": true
    },
    "Cookies": {
      "Behavior": "reject-tracker-and-partition-foreign"
    },
    "FirefoxHome": {
      "TopSites": false,
      "SponsoredTopSites": false,
      "Highlights": false,
      "Pocket": false,
      "SponsoredPocket": false,
      "Snippets": false
    },
    "FirefoxSuggest": {
      "WebSuggestions": false,
      "SponsoredSuggestions": false,
      "ImproveSuggest": false
    },
    "Permissions": {
      "Camera":       { "BlockNewRequests": true, "Locked": true },
      "Microphone":   { "BlockNewRequests": true, "Locked": true },
      "Location":     { "BlockNewRequests": true, "Locked": true },
      "Notifications":{ "BlockNewRequests": true, "Locked": true }
    },
    "Preferences": {
      "general.useragent.override":        { "Value": "${CUSTOM_UA}",         "Status": "locked" },
      "general.platform.override":         { "Value": "${CUSTOM_UA_PLATFORM}", "Status": "locked" },
      "general.oscpu.override":            { "Value": "${CUSTOM_UA_OSCPU}",   "Status": "locked" },
      "general.appversion.override":       { "Value": "${CUSTOM_UA_APPVERSION}", "Status": "locked" },
      "general.buildID.override":          { "Value": "${CUSTOM_UA_BUILDID}", "Status": "locked" },
      "browser.startup.homepage_override.buildID": { "Value": "${CUSTOM_UA_BUILDID}", "Status": "locked" },
      "intl.accept_languages":             { "Value": "${CUSTOM_ACCEPT_LANG}", "Status": "locked" },

      "privacy.fingerprintingProtection":  { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.enabled":{ "Value": true, "Status": "locked" },
      "privacy.trackingprotection.fingerprinting.enabled": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.cryptomining.enabled":   { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.socialtracking.enabled": { "Value": true, "Status": "locked" },
      "privacy.trackingprotection.emailtracking.enabled":  { "Value": true, "Status": "locked" },
      "privacy.donottrackheader.enabled":  { "Value": true, "Status": "locked" },
      "privacy.globalprivacycontrol.enabled": { "Value": true, "Status": "locked" },
      "privacy.firstparty.isolate":        { "Value": true, "Status": "locked" },

      "media.peerconnection.enabled":                 { "Value": true,  "Status": "locked" },
      "media.peerconnection.ice.default_address_only":{ "Value": true,  "Status": "locked" },
      "media.peerconnection.ice.no_host":             { "Value": true,  "Status": "locked" },
      "media.peerconnection.ice.proxy_only_if_behind_proxy": { "Value": true, "Status": "locked" },
      "media.peerconnection.ice.obfuscate_host_addresses":   { "Value": true, "Status": "locked" },
      "media.navigator.enabled":           { "Value": true,  "Status": "default" },

      "webgl.disabled":                    { "Value": false, "Status": "default" },
      "webgl.enable-debug-renderer-info":  { "Value": false, "Status": "locked" },
      "geo.enabled":                       { "Value": false, "Status": "locked" },
      "dom.battery.enabled":               { "Value": false, "Status": "locked" },
      "dom.event.clipboardevents.enabled": { "Value": false, "Status": "locked" },
      "dom.webaudio.enabled":              { "Value": true,  "Status": "default" },
      "dom.webnotifications.enabled":      { "Value": false, "Status": "locked" },
      "dom.push.enabled":                  { "Value": false, "Status": "locked" },
      "dom.serviceWorkers.enabled":        { "Value": true,  "Status": "default" },
      "dom.gamepad.enabled":               { "Value": false, "Status": "locked" },
      "dom.vr.enabled":                    { "Value": false, "Status": "locked" },
      "dom.netinfo.enabled":               { "Value": false, "Status": "locked" },

      "network.http.referer.XOriginPolicy":     { "Value": 2, "Status": "locked" },
      "network.http.referer.XOriginTrimmingPolicy": { "Value": 2, "Status": "locked" },
      "network.http.referer.spoofSource":       { "Value": true, "Status": "locked" },
      "network.dns.disablePrefetch":            { "Value": true, "Status": "locked" },
      "network.predictor.enabled":              { "Value": false, "Status": "locked" },
      "network.prefetch-next":                  { "Value": false, "Status": "locked" },
      "network.captive-portal-service.enabled": { "Value": false, "Status": "locked" },
      "network.connectivity-service.enabled":   { "Value": false, "Status": "locked" },
      "network.proxy.socks_remote_dns":         { "Value": true, "Status": "locked" },
      "network.IDN_show_punycode":              { "Value": true, "Status": "locked" },

      "browser.send_pings":                { "Value": false, "Status": "locked" },
      "browser.urlbar.suggest.searches":   { "Value": false, "Status": "locked" },
      "browser.urlbar.speculativeConnect.enabled": { "Value": false, "Status": "locked" },
      "browser.search.suggest.enabled":    { "Value": false, "Status": "locked" },
      "browser.formfill.enable":           { "Value": false, "Status": "locked" },
      "browser.safebrowsing.downloads.remote.enabled": { "Value": false, "Status": "locked" },

      "beacon.enabled":                    { "Value": false, "Status": "locked" },
      "device.sensors.enabled":            { "Value": false, "Status": "locked" },
      "media.video_stats.enabled":         { "Value": false, "Status": "locked" },
      "media.eme.enabled":                 { "Value": false, "Status": "locked" },

      "datareporting.policy.dataSubmissionEnabled": { "Value": false, "Status": "locked" },
      "datareporting.healthreport.uploadEnabled":   { "Value": false, "Status": "locked" },
      "toolkit.telemetry.unified":         { "Value": false, "Status": "locked" },
      "toolkit.telemetry.enabled":         { "Value": false, "Status": "locked" },
      "toolkit.telemetry.archive.enabled": { "Value": false, "Status": "locked" },
      "extensions.pocket.enabled":         { "Value": false, "Status": "locked" },
      "extensions.formautofill.addresses.enabled":  { "Value": false, "Status": "locked" },
      "extensions.formautofill.creditCards.enabled":{ "Value": false, "Status": "locked" }
    }
  }
}
UAFF
chmod 644 /etc/firefox/policies/policies.json

# 5) Chromium-family: launch flags = the only system-level fingerprint knob.
# Disables UA Client Hints (so navigator.userAgentData is suppressed and only
# our spoofed UA string is visible), WebRTC IP leaks, telemetry, prefetching,
# Topics/FLoC/FedCM.
mkdir -p /etc/skel/.config "/home/${USERNAME}/.config"
CHROMIUM_FLAGS=$(cat <<CFLAGS
--user-agent=${CUSTOM_UA}
--accept-lang=${CUSTOM_ACCEPT_LANG}
--disable-features=UserAgentClientHint,UserAgentClientHintFullVersionList,UserAgentReduction,Topics,InterestCohortAPI,InterestGroupStorage,WebRtcAllowInputVolumeAdjustment,PrivacySandboxAdsAPIs,AttributionReportingAPI
--no-pings
--no-default-browser-check
--no-first-run
--disable-background-networking
--disable-domain-reliability
--disable-sync
--disable-breakpad
--disable-crash-reporter
--metrics-recording-only=false
--disable-component-extensions-with-background-pages
--enforce-webrtc-ip-permission-check
--force-webrtc-ip-handling-policy=default_public_interface_only
--webrtc-ip-handling-policy=default_public_interface_only
--enable-features=WebRtcHideLocalIpsWithMdns
CFLAGS
)
for target in "/home/${USERNAME}/.config" /etc/skel/.config; do
    install -d -m 755 "$target"
    for flagfile in chromium-flags.conf chrome-flags.conf brave-flags.conf \
                    vivaldi-flags.conf opera-flags.conf microsoft-edge-flags.conf \
                    thorium-flags.conf; do
        printf '%s\n' "$CHROMIUM_FLAGS" > "$target/$flagfile"
    done
done
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" 2>/dev/null || true

# 6) Network stack fingerprint shims: bring TCP/IP signature closer to Windows.
# - IP TTL default = 128 (Windows) instead of 64 (Linux). p0f / passive OS
#   fingerprinters pick this up first.
# - TCP timestamps OFF: Windows disables them by default; Linux enables them
#   (which leaks uptime + makes the host trivially trackable across NATs).
# - tcp_window_scaling stays ON (both Windows and Linux do this).
# - tcp_sack stays ON (same).
cat > /etc/sysctl.d/99-fingerprint.conf <<'SYSCTLFP'
# Match Windows-ish TCP/IP fingerprint (arch-installer).
#
# Kernel-level knobs we CAN tune without breaking anything. The remaining
# difference vs a real Win11 stack is the TCP option ORDER in SYN packets
# (Linux sends MSS-SACK_PERM-TS-NOP-WSopt; Windows sends MSS-NOP-WSopt-NOP-
# NOP-SACK_PERM). That ordering is hardcoded in the kernel's tcp_options_write
# and is NOT reachable from iptables/nftables/sysctl. Spoofing it requires
# either a custom kernel patch or a userspace NFQUEUE rewriter -- both add
# fragility we deliberately avoid.

# --- IP layer ---
net.ipv4.ip_default_ttl         = 128
net.ipv6.conf.default.hop_limit = 128
net.ipv6.conf.all.hop_limit     = 128

# --- TCP layer: timestamps + selective-ACK behaviour ---
net.ipv4.tcp_timestamps         = 0
net.ipv4.tcp_dsack              = 0

# --- TCP layer: explicit congestion notification (Win10 1709+ enables it) ---
net.ipv4.tcp_ecn                = 1
net.ipv4.tcp_ecn_fallback       = 1

# --- TCP layer: SYN retransmit budgets (Win uses 2, Linux defaults 6/5) ---
net.ipv4.tcp_syn_retries        = 2
net.ipv4.tcp_synack_retries     = 2

# --- TCP layer: keep-alive cadence (matches Win11 defaults) ---
net.ipv4.tcp_keepalive_time     = 7200
net.ipv4.tcp_keepalive_intvl    = 1
net.ipv4.tcp_keepalive_probes   = 10

# --- TCP layer: connection lifecycle ---
net.ipv4.tcp_fin_timeout        = 60
net.ipv4.tcp_tw_reuse           = 0

# --- TCP layer: SYN backlog under load (Win small, Linux huge) ---
net.ipv4.tcp_max_syn_backlog    = 256

# --- TCP layer: MTU probing (Win11 enables PMTUD) ---
net.ipv4.tcp_mtu_probing        = 1
net.ipv4.ip_no_pmtu_disc        = 0
SYSCTLFP
chmod 644 /etc/sysctl.d/99-fingerprint.conf

# 7) DNS over HTTPS for the system resolver (matches Edge default behaviour
# on Win11 + breaks the easy "ISP sees DNS" leak). Uses Cloudflare as a
# vendor-neutral resolver; user can override later in NetworkManager.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/00-doh.conf <<'DOHCONF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
DOHCONF
chmod 644 /etc/systemd/resolved.conf.d/00-doh.conf

# mkinitcpio (BTRFS + LUKS + VMware controllers)
cat > /etc/mkinitcpio.conf <<'MKINIT'
MODULES=(btrfs
         vmw_pvscsi vmw_balloon vmwgfx mptsas mpt3sas mptspi BusLogic
         virtio virtio_blk virtio_pci virtio_net virtio_scsi virtio_balloon virtio_gpu virtio_console
         vboxguest vboxsf vboxvideo
         hv_vmbus hv_storvsc hv_netvsc hv_balloon
         ahci nvme xhci_pci ehci_pci uhci_hcd sd_mod sr_mod usbhid)
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

# === Hardware identity spoofing (DMI/SMBIOS + machine-id + hostid) ===
# Goal: any app that reads system fingerprint via dmidecode, /sys/class/dmi/id,
# /etc/machine-id, /etc/hostid, dbus machine-id sees a coherent OEM laptop
# identity instead of "VMware Virtual Platform" or whatever the host firmware
# advertises. The vendor + model + serials are picked together from a curated
# DB (so a "Dell" system has Dell BIOS + Latitude product + Dell-format serial).
echo "[CHROOT] Setting up persistent hardware identity spoofing..."

mkdir -p /etc/spoof/dmi /etc/spoof/cache

# --- Vendor DB: vendor -> models (pipe-separated). Real consumer/business lines.
declare -A HWID_VENDORS=(
    ["Dell Inc."]="Latitude 7420|Latitude 7440|XPS 13 9320|XPS 15 9520|Precision 5570|Inspiron 16 5635"
    ["LENOVO"]="ThinkPad X1 Carbon Gen 11|ThinkPad T14 Gen 4|Yoga Slim 7 ProX|Legion Pro 7 16IRX8|IdeaPad 5 Pro 14ARH7"
    ["HP"]="EliteBook 840 G10|EliteBook 1040 G11|ZBook Studio G10|Pavilion 15-eg2056TX|OMEN by HP Laptop 16-xf0"
    ["ASUSTeK COMPUTER INC."]="ZenBook 14 UX3402VA|ROG Zephyrus G14 GA402XV|TUF Gaming A15 FA507|VivoBook Pro 15 K6502VV"
    ["Acer"]="Aspire 5 A515-57|Predator Helios 16 PH16-71|Swift 5 SF514-56T|Nitro 16 AN16-41"
    ["Micro-Star International Co., Ltd."]="GE76 Raider 12UH|GS66 Stealth 11UG|Modern 15 B12M|Stealth 17 Studio A13V"
    ["Razer"]="Blade 15 Advanced Model|Blade 17 Pro Model|Razer Book 13"
    ["Samsung Electronics Co., Ltd."]="Galaxy Book4 Pro|Galaxy Book4 Ultra|Galaxy Book Flex2 Alpha"
    ["Microsoft Corporation"]="Surface Laptop 5|Surface Pro 9|Surface Studio Laptop"
)

# BIOS vendor / version templates per system vendor (realistic strings)
declare -A HWID_BIOS_VENDOR=(
    ["Dell Inc."]="Dell Inc."
    ["LENOVO"]="LENOVO"
    ["HP"]="AMI"
    ["ASUSTeK COMPUTER INC."]="American Megatrends Inc."
    ["Acer"]="Insyde Corp."
    ["Micro-Star International Co., Ltd."]="American Megatrends International, LLC."
    ["Razer"]="American Megatrends International, LLC."
    ["Samsung Electronics Co., Ltd."]="American Megatrends Inc."
    ["Microsoft Corporation"]="Microsoft Corporation"
)
declare -A HWID_BIOS_VERSION=(
    ["Dell Inc."]="1.21.0"
    ["LENOVO"]="N3UET86W (1.51 )"
    ["HP"]="W17 Ver. 01.20.00"
    ["ASUSTeK COMPUTER INC."]="UX3402VA.302"
    ["Acer"]="V1.16"
    ["Micro-Star International Co., Ltd."]="E17S6IMS.10C"
    ["Razer"]="1.05"
    ["Samsung Electronics Co., Ltd."]="P12SAA.001.230927.JK"
    ["Microsoft Corporation"]="14.110.146"
)

# --- Pick a vendor + model
vendors=("${!HWID_VENDORS[@]}")
SPOOF_VENDOR="${vendors[RANDOM % ${#vendors[@]}]}"
IFS='|' read -ra MODELS <<< "${HWID_VENDORS[$SPOOF_VENDOR]}"
SPOOF_MODEL="${MODELS[RANDOM % ${#MODELS[@]}]}"
SPOOF_BIOS_VENDOR="${HWID_BIOS_VENDOR[$SPOOF_VENDOR]}"
SPOOF_BIOS_VERSION="${HWID_BIOS_VERSION[$SPOOF_VENDOR]}"

# --- Generate UUIDs and vendor-specific serials
gen_upper_uuid() { uuidgen | tr 'a-z' 'A-Z'; }
gen_serial_dell() {
    # Dell Service Tag: 7 chars, alphanumeric uppercase, no I/O confusion
    local chars="ABCDEFGHJKLMNPQRSTUVWXYZ0123456789" out="" i
    for i in 1 2 3 4 5 6 7; do out+="${chars:RANDOM%${#chars}:1}"; done
    printf '%s' "$out"
}
gen_serial_hp() {
    # HP serial: 10 chars uppercase alphanum, often starts with letter
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" out="" i
    for i in 1 2 3 4 5 6 7 8 9 10; do out+="${chars:RANDOM%${#chars}:1}"; done
    printf '%s' "$out"
}
gen_serial_lenovo() {
    # Lenovo: 8 chars alphanumeric uppercase
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" out="" i
    for i in 1 2 3 4 5 6 7 8; do out+="${chars:RANDOM%${#chars}:1}"; done
    printf '%s' "$out"
}
gen_serial_generic() {
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" out="" i
    local len=$(( 10 + RANDOM % 5 ))
    for ((i=0; i<len; i++)); do out+="${chars:RANDOM%${#chars}:1}"; done
    printf '%s' "$out"
}

case "$SPOOF_VENDOR" in
    "Dell Inc.")  SPOOF_SYS_SERIAL="$(gen_serial_dell)" ;;
    "HP")          SPOOF_SYS_SERIAL="$(gen_serial_hp)" ;;
    "LENOVO")      SPOOF_SYS_SERIAL="$(gen_serial_lenovo)" ;;
    *)             SPOOF_SYS_SERIAL="$(gen_serial_generic)" ;;
esac
SPOOF_BB_SERIAL="$(gen_serial_generic)"
SPOOF_CHASSIS_SERIAL="$(gen_serial_generic)"
SPOOF_SYSTEM_UUID="$(gen_upper_uuid)"

# Random-ish BIOS release date in the last 12 months
SPOOF_BIOS_DATE="$(date -d "$((RANDOM % 360 + 30)) days ago" '+%m/%d/%Y' 2>/dev/null || echo '01/15/2024')"

# --- Persist the chosen profile
cat > /etc/spoof/profile <<SPOOFP
# Persistent hardware identity (arch-installer)
SPOOF_VENDOR='${SPOOF_VENDOR}'
SPOOF_MODEL='${SPOOF_MODEL}'
SPOOF_SYS_SERIAL='${SPOOF_SYS_SERIAL}'
SPOOF_BB_SERIAL='${SPOOF_BB_SERIAL}'
SPOOF_CHASSIS_SERIAL='${SPOOF_CHASSIS_SERIAL}'
SPOOF_SYSTEM_UUID='${SPOOF_SYSTEM_UUID}'
SPOOF_BIOS_VENDOR='${SPOOF_BIOS_VENDOR}'
SPOOF_BIOS_VERSION='${SPOOF_BIOS_VERSION}'
SPOOF_BIOS_DATE='${SPOOF_BIOS_DATE}'
SPOOFP
chmod 644 /etc/spoof/profile

# --- Write spoofed DMI files (will be bind-mounted over /sys/class/dmi/id/*)
write_dmi() { printf '%s\n' "$2" > "/etc/spoof/dmi/$1"; chmod 644 "/etc/spoof/dmi/$1"; }
write_dmi sys_vendor          "${SPOOF_VENDOR}"
write_dmi product_name        "${SPOOF_MODEL}"
write_dmi product_version     "1.0"
write_dmi product_serial      "${SPOOF_SYS_SERIAL}"
write_dmi product_uuid        "${SPOOF_SYSTEM_UUID}"
write_dmi product_sku         "${SPOOF_MODEL%% *}_SKU_${SPOOF_SYS_SERIAL}"
write_dmi product_family      "${SPOOF_MODEL%% *}"
write_dmi board_vendor        "${SPOOF_VENDOR}"
write_dmi board_name          "${SPOOF_MODEL}"
write_dmi board_version       "1.0"
write_dmi board_serial        "${SPOOF_BB_SERIAL}"
write_dmi board_asset_tag     "0"
write_dmi chassis_vendor      "${SPOOF_VENDOR}"
write_dmi chassis_type        "10"   # 10 = Notebook (per SMBIOS spec)
write_dmi chassis_version     "1.0"
write_dmi chassis_serial      "${SPOOF_CHASSIS_SERIAL}"
write_dmi chassis_asset_tag   "0"
write_dmi bios_vendor         "${SPOOF_BIOS_VENDOR}"
write_dmi bios_version        "${SPOOF_BIOS_VERSION}"
write_dmi bios_date           "${SPOOF_BIOS_DATE}"

# --- systemd service that bind-mounts the spoofed files over /sys at boot
cat > /usr/local/sbin/dmi-spoof-mount <<'DMIMNT'
#!/usr/bin/env bash
# Bind-mount /etc/spoof/dmi/<field> over /sys/class/dmi/id/<field>.
# /sys is a sysfs pseudo-fs but bind-mount over individual files works fine.
SRC=/etc/spoof/dmi
TGT=/sys/class/dmi/id
[[ -d "$SRC" && -d "$TGT" ]] || exit 0
shopt -s nullglob
for f in "$SRC"/*; do
    name="$(basename "$f")"
    [[ -e "$TGT/$name" ]] || continue
    mountpoint -q "$TGT/$name" && continue
    mount --bind "$f" "$TGT/$name" 2>/dev/null || true
done
exit 0
DMIMNT
chmod 755 /usr/local/sbin/dmi-spoof-mount

cat > /etc/systemd/system/dmi-spoof.service <<'DMISVC'
[Unit]
Description=Bind-mount spoofed DMI/SMBIOS data over /sys/class/dmi/id
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target sysinit-late.service NetworkManager.service systemd-logind.service
ConditionPathIsDirectory=/sys/class/dmi/id

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/dmi-spoof-mount

[Install]
WantedBy=basic.target
DMISVC
systemctl enable dmi-spoof.service 2>/dev/null || true

# --- dmidecode shim: wraps the real binary, fakes the queried strings
mv -f /usr/bin/dmidecode /usr/bin/dmidecode.real 2>/dev/null || true
cat > /usr/local/sbin/dmidecode-shim <<'DMISHIM'
#!/usr/bin/env bash
# Shim around /usr/bin/dmidecode.real that returns spoofed data for the
# common -s/--string and -t/--type queries; falls through for everything else.
[[ -f /etc/spoof/profile ]] && source /etc/spoof/profile
REAL=/usr/bin/dmidecode.real

# Single string: dmidecode -s <field>
if [[ "$1" == "-s" || "$1" == "--string" ]]; then
    case "${2:-}" in
        system-manufacturer)        printf '%s\n' "${SPOOF_VENDOR}";        exit 0 ;;
        system-product-name)        printf '%s\n' "${SPOOF_MODEL}";         exit 0 ;;
        system-version)             printf '%s\n' "1.0";                    exit 0 ;;
        system-serial-number)       printf '%s\n' "${SPOOF_SYS_SERIAL}";    exit 0 ;;
        system-uuid)                printf '%s\n' "${SPOOF_SYSTEM_UUID}";   exit 0 ;;
        system-family)              printf '%s\n' "${SPOOF_MODEL%% *}";     exit 0 ;;
        system-sku-number)          printf '%s\n' "${SPOOF_MODEL%% *}_SKU"; exit 0 ;;
        baseboard-manufacturer)     printf '%s\n' "${SPOOF_VENDOR}";        exit 0 ;;
        baseboard-product-name)     printf '%s\n' "${SPOOF_MODEL}";         exit 0 ;;
        baseboard-version)          printf '%s\n' "1.0";                    exit 0 ;;
        baseboard-serial-number)    printf '%s\n' "${SPOOF_BB_SERIAL}";     exit 0 ;;
        baseboard-asset-tag)        printf '%s\n' "0";                      exit 0 ;;
        chassis-manufacturer)       printf '%s\n' "${SPOOF_VENDOR}";        exit 0 ;;
        chassis-type)               printf '%s\n' "Notebook";               exit 0 ;;
        chassis-version)            printf '%s\n' "1.0";                    exit 0 ;;
        chassis-serial-number)      printf '%s\n' "${SPOOF_CHASSIS_SERIAL}";exit 0 ;;
        chassis-asset-tag)          printf '%s\n' "0";                      exit 0 ;;
        bios-vendor)                printf '%s\n' "${SPOOF_BIOS_VENDOR}";   exit 0 ;;
        bios-version)               printf '%s\n' "${SPOOF_BIOS_VERSION}";  exit 0 ;;
        bios-release-date)          printf '%s\n' "${SPOOF_BIOS_DATE}";     exit 0 ;;
        *)  exec "$REAL" "$@" ;;
    esac
fi

# Type filter: dmidecode -t N or -t name
emit_bios() { cat <<EOB
Handle 0x0000, DMI type 0, 26 bytes
BIOS Information
	Vendor: ${SPOOF_BIOS_VENDOR}
	Version: ${SPOOF_BIOS_VERSION}
	Release Date: ${SPOOF_BIOS_DATE}
	ROM Size: 16 MB
	Characteristics:
		PCI is supported
		BIOS is upgradeable
		BIOS shadowing is allowed
		Boot from CD is supported
		Selectable boot is supported
		EDD is supported
		ACPI is supported
		USB legacy is supported
		UEFI is supported
EOB
}
emit_system() { cat <<EOS
Handle 0x0001, DMI type 1, 27 bytes
System Information
	Manufacturer: ${SPOOF_VENDOR}
	Product Name: ${SPOOF_MODEL}
	Version: 1.0
	Serial Number: ${SPOOF_SYS_SERIAL}
	UUID: ${SPOOF_SYSTEM_UUID}
	Wake-up Type: Power Switch
	SKU Number: ${SPOOF_MODEL%% *}_SKU
	Family: ${SPOOF_MODEL%% *}
EOS
}
emit_baseboard() { cat <<EOB
Handle 0x0002, DMI type 2, 15 bytes
Base Board Information
	Manufacturer: ${SPOOF_VENDOR}
	Product Name: ${SPOOF_MODEL}
	Version: 1.0
	Serial Number: ${SPOOF_BB_SERIAL}
	Asset Tag: 0
	Features:
		Board is a hosting board
		Board is replaceable
	Type: Motherboard
EOB
}
emit_chassis() { cat <<EOC
Handle 0x0003, DMI type 3, 22 bytes
Chassis Information
	Manufacturer: ${SPOOF_VENDOR}
	Type: Notebook
	Lock: Not Present
	Version: 1.0
	Serial Number: ${SPOOF_CHASSIS_SERIAL}
	Asset Tag: 0
	Boot-up State: Safe
	Power Supply State: Safe
	Thermal State: Safe
	Security Status: None
EOC
}

if [[ "$1" == "-t" || "$1" == "--type" ]]; then
    case "${2:-}" in
        0|bios)        emit_bios;     exit 0 ;;
        1|system)      emit_system;   exit 0 ;;
        2|baseboard)   emit_baseboard;exit 0 ;;
        3|chassis)     emit_chassis;  exit 0 ;;
        *)  exec "$REAL" "$@" ;;
    esac
fi

# No args: full synthetic dump
if [[ $# -eq 0 ]]; then
    cat <<EOF
# dmidecode 3.5
Getting SMBIOS data from sysfs.
SMBIOS 3.4.0 present.

EOF
    emit_bios; echo
    emit_system; echo
    emit_baseboard; echo
    emit_chassis; echo
    exit 0
fi

# Anything else: defer to the real binary
exec "$REAL" "$@"
DMISHIM
chmod 755 /usr/local/sbin/dmidecode-shim

# Thin /usr/bin/dmidecode that calls the shim
cat > /usr/bin/dmidecode <<'DMITHIN'
#!/usr/bin/env bash
exec /usr/local/sbin/dmidecode-shim "$@"
DMITHIN
chmod 755 /usr/bin/dmidecode

# Pacman hook: re-shim after every dmidecode pkg upgrade
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/99-dmidecode-spoof.hook <<'PACHOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/bin/dmidecode

[Action]
Description = Re-installing spoofed dmidecode shim
When = PostTransaction
Exec = /usr/local/sbin/dmidecode-reshim
PACHOOK

cat > /usr/local/sbin/dmidecode-reshim <<'RESHIM'
#!/usr/bin/env bash
# Re-applied after pacman upgrades dmidecode: move the new real binary aside
# and restore our thin wrapper.
[[ -f /usr/bin/dmidecode && ! -L /usr/bin/dmidecode ]] || exit 0
# Detect: real binaries are ELF; our wrapper is a tiny bash script
if file -b /usr/bin/dmidecode 2>/dev/null | grep -q ELF; then
    mv -f /usr/bin/dmidecode /usr/bin/dmidecode.real
    cat > /usr/bin/dmidecode <<'INNER'
#!/usr/bin/env bash
exec /usr/local/sbin/dmidecode-shim "$@"
INNER
    chmod 755 /usr/bin/dmidecode
fi
RESHIM
chmod 755 /usr/local/sbin/dmidecode-reshim

# --- Random /etc/machine-id, /var/lib/dbus/machine-id, /etc/hostid
# These are queried by systemd, journald, dbus, and many fingerprinting libs.
rm -f /etc/machine-id
systemd-machine-id-setup --commit 2>/dev/null \
    || head -c 16 /dev/urandom | xxd -p | tr -d '\n' > /etc/machine-id
[[ -s /etc/machine-id ]] || head -c 16 /dev/urandom | xxd -p | tr -d '\n' > /etc/machine-id
echo "" >> /etc/machine-id
mkdir -p /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# /etc/hostid: 4-byte random ID (used by gethostid(3), some legacy daemons)
dd if=/dev/urandom of=/etc/hostid bs=4 count=1 status=none

echo "[CHROOT] HWID spoofed: ${SPOOF_VENDOR} / ${SPOOF_MODEL} / SN=${SPOOF_SYS_SERIAL}"

# === Install yay (AUR helper) + Windows-11 font pack ===
# This is the LAST package step before credentials are wiped. yay-bin is the
# prebuilt-binary flavour (no Go compile needed at install time). We grant
# ${USERNAME} a temporary NOPASSWD sudo, then revoke it. ttf-ms-win11-auto
# downloads the Win11 system fonts from a Microsoft mirror and packages them
# locally -- this completes the browser-fingerprint font story (Segoe UI,
# Cascadia, Calibri, etc.). Both steps are best-effort: if the network is
# flaky or the AUR is down, the install still completes.
echo "[CHROOT] Installing yay (AUR helper) + ttf-ms-win11-auto..."

# Temporary NOPASSWD sudo just for makepkg/pacman during this build
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/00-aurbuild
chmod 440 /etc/sudoers.d/00-aurbuild

if runuser -u "${USERNAME}" -- bash -c '
    set -e
    rm -rf /tmp/yay-bin
    git clone --depth=1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin
    makepkg -si --noconfirm --needed
'; then
    echo "[CHROOT] yay installed."
    runuser -u "${USERNAME}" -- bash -c 'yay -S --noconfirm --needed ttf-ms-win11-auto' \
        && echo "[CHROOT] ttf-ms-win11-auto installed -- Win11 fonts are present." \
        || echo "[CHROOT-WARN] ttf-ms-win11-auto failed; falling back to Liberation/Noto stack." >&2
    # Refresh font cache so newly-installed fonts are immediately discoverable
    fc-cache -fv >/dev/null 2>&1 || true
else
    echo "[CHROOT-WARN] yay-bin build failed; ttf-ms-win11-auto skipped. Run later: 'yay -S ttf-ms-win11-auto'" >&2
fi

# Revoke the temporary NOPASSWD sudo
rm -f /etc/sudoers.d/00-aurbuild

# Clean build leftovers
rm -rf /tmp/yay-bin

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
