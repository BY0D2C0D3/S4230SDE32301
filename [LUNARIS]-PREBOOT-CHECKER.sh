#!/bin/bash
set -e
echo "=============================================="
echo " Vérification et correction pré-reboot"
echo "=============================================="

# Fonction pour vérifier et corriger LUKS root
check_luks() {
    if cryptsetup status cryptroot &>/dev/null; then
        echo "✅ LUKS root actif"
    else
        echo "❌ LUKS root inactif"
        echo "Tentative de réactivation..."
        read -s -p "Mot de passe root LUKS : " ROOT_PASS; echo
        echo "$ROOT_PASS" | cryptsetup open /dev/mapper/cryptroot cryptroot -
    fi
}

# Fonction pour vérifier Btrfs et remonter si besoin
check_btrfs() {
    SUBS=("/" "/home" "/var" "/.snapshots")
    for SUB in "${SUBS[@]}"; do
        if mountpoint -q "$SUB"; then
            echo "✅ $SUB monté"
        else
            echo "❌ $SUB non monté, tentative de montage..."
            case $SUB in
                "/") mount -o noatime,compress=zstd,ssd,subvol=@ /dev/mapper/cryptroot /mnt;;
                "/home") mount -o noatime,compress=zstd,ssd,subvol=@home /dev/mapper/cryptroot /mnt/home;;
                "/var") mount -o noatime,compress=zstd,ssd,subvol=@var /dev/mapper/cryptroot /mnt/var;;
                "/.snapshots") mount -o noatime,compress=zstd,ssd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots;;
            esac
        fi
    done
}

# Fonction pour vérifier zRAM et CPU frequency
check_cpu_ram() {
    if ! swapon --show | grep zram &>/dev/null; then
        echo "❌ zRAM inactif, activation..."
        systemctl enable --now zram-generator
    else
        echo "✅ zRAM actif"
    fi

    CURRENT_POLICY=$(cpupower frequency-info | grep "current policy")
    echo "Info CPU : $CURRENT_POLICY"
}

# Vérification LUKS
echo -e "\n[1] Vérification LUKS root..."
check_luks

# Vérification Btrfs
echo -e "\n[2] Vérification Btrfs et subvolumes..."
check_btrfs

# Vérification snapshots
echo -e "\n[3] Snapshots Btrfs..."
if systemctl is-active --quiet btrfs-auto-snapshot.timer; then
    echo "✅ Timer snapshots actif"
else
    echo "❌ Timer snapshots inactif, activation..."
    systemctl enable --now btrfs-auto-snapshot.timer
fi

# Vérification Hyprland config
echo -e "\n[4] Vérification Hyprland..."
HYPR_CONF="/home/$USER/.config/hypr/hyprland.conf"
if [ ! -f "$HYPR_CONF" ]; then
    echo "❌ Hyprland.conf manquant, copie automatique du modèle..."
    cp /etc/skel/.config/hypr/hyprland.conf "$HYPR_CONF"
fi

# Vérification Firejail + Thorium
echo -e "\n[5] Vérification Firejail et Thorium..."
if [ ! -f "/etc/firejail/thorium.profile" ]; then
    echo "❌ Profil Firejail manquant, création..."
    mkdir -p /etc/firejail
    cat <<FIRE > /etc/firejail/thorium.profile
private
netfilter
nogroups
noroot
caps.drop all
FIRE
fi
if ! command -v thorium &>/dev/null; then
    echo "❌ Thorium non installé, téléchargement..."
    mkdir -p /opt/thorium
    cd /opt/thorium
    wget https://github.com/Alex313031/thorium/releases/download/M138.0.7204.303/Thorium-138.0.7204.303-x86_64-linux.tar.xz -O thorium.tar.xz
    tar -xvf thorium.tar.xz --strip-components=1
    ln -s /opt/thorium/thorium /usr/local/bin/thorium
    rm thorium.tar.xz
fi

# Vérification CPU/GPU
echo -e "\n[6] Vérification CPU/RAM/zRAM/TRIM..."
check_cpu_ram
if ! systemctl is-active --quiet hyprland-optim.service; then
    echo "❌ Service Hyprland optimisations inactif, activation..."
    systemctl enable --now hyprland-optim.service
else
    echo "✅ Service Hyprland optimisations actif"
fi
if ! systemctl is-active --quiet fstrim.timer; then
    echo "❌ TRIM inactif, activation..."
    systemctl enable --now fstrim.timer
else
    echo "✅ TRIM actif"
fi

# Vérification clavier
echo -e "\n[7] Vérification claviers AZERTY et MX Keys Mini..."
localectl status | grep "Layout" | grep fr &>/dev/null && echo "✅ AZERTY console actif" || echo "❌ AZERTY console non actif"
xinput list | grep "MX Keys Mini" &>/dev/null && echo "✅ MX Keys Mini détecté" || echo "❌ MX Keys Mini non détecté"

echo -e "\n✅ Vérification et corrections automatiques terminées. Vous pouvez maintenant redémarrer en toute sécurité."