#!/bin/bash
set -e
clear
echo "=============================================="
echo " Arch Ultimate Expert v4.3 Installer"
echo " TUI complet + Hyprland Ultra-Boost + Security"
echo "=============================================="

# -----------------------------
# 1️⃣ TUI : sélection du disque
# -----------------------------
DISKS=($(lsblk -dno NAME,MODEL | awk '{print "/dev/" $1 " - " $2}'))
echo "Sélectionnez le disque pour l'installation :"
select INSTALL_DISK_FULL in "${DISKS[@]}"; do
    INSTALL_DISK=$(echo $INSTALL_DISK_FULL | awk '{print $1}')
    echo "Disque choisi : $INSTALL_DISK"
    break
done

# -----------------------------
# 2️⃣ TUI : mode d'installation
# -----------------------------
echo "Mode d'installation :"
select INSTALL_MODE in "clean" "dual-boot"; do
    echo "Mode choisi : $INSTALL_MODE"
    break
done

# -----------------------------
# 3️⃣ TUI : choix CPU microcode
# -----------------------------
echo "Choisissez votre CPU :"
select CPU_MICROCODE in "amd" "intel"; do
    break
done

# -----------------------------
# 4️⃣ TUI : utilisateur
# -----------------------------
read -p "Nom de l'utilisateur principal : " USER_NAME
read -s -p "Mot de passe root : " ROOT_PASS; echo
read -s -p "Mot de passe utilisateur : " USER_PASS; echo

# -----------------------------
# 5️⃣ Partitionnement et chiffrement
# -----------------------------
[[ "$INSTALL_MODE" == "clean" ]] && wipefs -a $INSTALL_DISK
parted $INSTALL_DISK -- mklabel gpt
parted $INSTALL_DISK -- mkpart ESP fat32 1MiB 512MiB
parted $INSTALL_DISK -- set 1 esp on
parted $INSTALL_DISK -- mkpart primary 512MiB 100%
ESP="${INSTALL_DISK}1"
ROOT_PART="${INSTALL_DISK}2"
echo "$ROOT_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id $ROOT_PART -
echo "$ROOT_PASS" | cryptsetup open $ROOT_PART cryptroot -

# -----------------------------
# 6️⃣ Btrfs + subvolumes
# -----------------------------
mkfs.fat -F32 $ESP
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt
mount -o noatime,compress=zstd,ssd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var,.snapshots,boot}
mount -o noatime,compress=zstd,ssd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,ssd,subvol=@var /dev/mapper/cryptroot /mnt/var
mount -o noatime,compress=zstd,ssd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount $ESP /mnt/boot

# -----------------------------
# 7️⃣ Installation base Arch
# -----------------------------
pacstrap /mnt base linux-zen linux-firmware $CPU_MICROCODE sudo base-devel git nano
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# 8️⃣ Chroot post-install
# -----------------------------
arch-chroot /mnt /bin/bash <<'EOFCHROOT'
set -e

# -----------------------------
# Locale + Claviers
# -----------------------------
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
localectl set-keymap fr
localectl set-x11-keymap fr pc105 '' azerty

# Configuration spécifique Logitech MX Keys Mini
mkdir -p /etc/X11/xorg.conf.d/
cat <<EOF > /etc/X11/xorg.conf.d/90-mxkeys-mini.conf
Section "InputClass"
    Identifier "MX Keys Mini"
    MatchProduct "MX Keys Mini"
    Option "XkbLayout" "fr"
    Option "XkbVariant" "azerty"
    Option "XkbOptions" "terminate:ctrl_alt_bksp"
EndSection
EOF

echo "arch-ultimate-v4.3" > /etc/hostname

# -----------------------------
# Utilisateur et sudo
# -----------------------------
useradd -m -G wheel -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$ROOT_PASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# -----------------------------
# NetworkManager
# -----------------------------
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

# -----------------------------
# Bootloader systemd-boot
# -----------------------------
bootctl install
UUID_ROOT=$(blkid -s UUID -o value /dev/mapper/cryptroot)
cat <<EOL > /boot/loader/entries/arch.conf
title Arch Linux Ultimate Expert v4.3
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options cryptdevice=UUID=$UUID_ROOT:cryptroot root=/dev/mapper/cryptroot rw quiet
EOL

# -----------------------------
# Hyprland + Wayland stack
# -----------------------------
pacman -S --noconfirm hyprland wayland wayland-protocols wlroots xorg-xwayland alacritty waybar wofi mako pamixer

if lspci | grep -i nvidia &>/dev/null; then
    pacman -S --noconfirm nvidia nvidia-utils nvidia-settings vulkan-icd-loader lib32-nvidia-utils
elif lspci | grep -i amd &>/dev/null; then
    pacman -S --noconfirm xf86-video-amdgpu mesa vulkan-radeon lib32-mesa
fi

# -----------------------------
# CPU/RAM/zRAM + TRIM
# -----------------------------
pacman -S --noconfirm cpupower zram-generator
systemctl enable --now cpupower
cpupower frequency-set -g performance
systemctl enable --now zram-generator
echo "vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5" >> /etc/sysctl.d/99-memory.conf
systemctl enable --now fstrim.timer

# -----------------------------
# Hyprland Ultra-Boost + Autostart
# -----------------------------
mkdir -p /home/$USER_NAME/.config/hypr
cat <<HYPR > /home/$USER_NAME/.config/hypr/hyprland.conf
[input]
kb_layout = fr
kb_variant = azerty
repeat_delay = 200
repeat_rate = 25
pointer_accel = 1.2
natural_scroll = true

[general]
master_gfx = "NVIDIA"
monitor_framerate_limit = 0
vsync = "full"
animated_workspaces = true
smooth_animations = true
animation_speed = 0.8
dpi = 160
blur_background = true
blur_strength = 5

[security]
no_xwayland = false
forbid_untrusted_wayland_clients = true
disable_global_shortcuts_in_sandbox = true
enforce_pam_restrictions = true

[window]
border_size = 2
border_color_active = "#00FFAA"
border_color_inactive = "#555555"
smart_borders = true
gaps_in = 10
gaps_out = 10

[workspace]
default_workspace = 1
autogroup_apps = true

[floating]
"popup*" = true
"dialog*" = true
"login*" = true

[monitor]
DP-1,1920x1080@144,0x0,1

[autostart]
mako &
pulseaudio --start &
waybar &
xdg-desktop-portal &
wl-clipboard-history &
nm-applet &
firejail --net=none thorium &
HYPR

cat <<AUTO > /home/$USER_NAME/.config/hypr/autostart.sh
#!/bin/bash
mako &
pulseaudio --start
waybar &
xdg-desktop-portal &
wl-clipboard-history &
nm-applet &
firejail --net=none thorium &
AUTO
chmod +x /home/$USER_NAME/.config/hypr/autostart.sh

# -----------------------------
# Firejail Profiles
# -----------------------------
mkdir -p /etc/firejail
cat <<FIRE > /etc/firejail/thorium.profile
private
netfilter
nogroups
noroot
caps.drop all
FIRE

# -----------------------------
# Thorium Browser
# -----------------------------
mkdir -p /opt/thorium
cd /opt/thorium
wget https://github.com/Alex313031/thorium/releases/download/M138.0.7204.303/Thorium-138.0.7204.303-x86_64-linux.tar.xz -O thorium.tar.xz
tar -xvf thorium.tar.xz --strip-components=1
ln -s /opt/thorium/thorium /usr/local/bin/thorium
rm thorium.tar.xz

# -----------------------------
# Snapshots Btrfs automatiques avec rotation
# -----------------------------
cat <<'SNAP' > /usr/local/bin/btrfs-auto-snapshot.sh
#!/bin/bash
SNAPSHOT_DIR="/.snapshots"
SUBVOLS=("/" "/home" "/var")
MAX_SNAPSHOTS=7
for SUB in "${SUBVOLS[@]}"; do
    BASENAME=$(basename $SUB)
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    SNAP_PATH="$SNAPSHOT_DIR/$BASENAME-$TIMESTAMP"
    btrfs subvolume snapshot -r $SUB $SNAP_PATH
    COUNT=$(ls -1 $SNAPSHOT_DIR | grep "^$BASENAME-" | wc -l)
    if [ "$COUNT" -gt "$MAX_SNAPSHOTS" ]; then
        TO_DELETE=$(ls -1t $SNAPSHOT_DIR | grep "^$BASENAME-" | tail -n +$(($MAX_SNAPSHOTS + 1)))
        for D in $TO_DELETE; do
            btrfs subvolume delete "$SNAPSHOT_DIR/$D"
        done
    fi
done
SNAP
chmod +x /usr/local/bin/btrfs-auto-snapshot.sh

# Systemd service + timer pour snapshots
cat <<SERVICE > /etc/systemd/system/btrfs-auto-snapshot.service
[Unit]
Description=Btrfs Automatic Snapshots
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-auto-snapshot.sh
[Install]
WantedBy=multi-user.target
SERVICE

cat <<TIMER > /etc/systemd/system/btrfs-auto-snapshot.timer
[Unit]
Description=Run Btrfs Auto Snapshots Daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now btrfs-auto-snapshot.timer

# -----------------------------
# Service systemd Hyprland optimisations
# -----------------------------
cat <<SERV2 > /etc/systemd/system/hyprland-optim.service
[Unit]
Description=Optimisations CPU/GPU pour Hyprland
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'cpupower frequency-set -g performance'
ExecStart=/usr/bin/bash -c 'echo "vm.swappiness=10" >> /etc/sysctl.d/99-memory.conf'
ExecStart=/usr/bin/bash -c 'echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.d/99-memory.conf'
[Install]
WantedBy=default.target
SERV2
systemctl daemon-reload
systemctl enable hyprland-optim.service

EOFCHROOT

echo "🎉 Installation v4.3 Ultimate Expert terminée ! Redémarrez pour profiter de votre système complet avec Hyprland Ultra-Boost et support MX Keys Mini AZERTY."
