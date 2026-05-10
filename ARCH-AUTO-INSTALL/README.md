
# PROCESS D'IMPORTATION ET D'EXECUTION DU DOSSIER COMPLET DU REPO.
pacman -Sy --noconfirm git
git clone --filter=blob:none --no-checkout --depth=1 https://github.com/SPARK/arch-vm-installer.git
cd arch-vm-installer
git sparse-checkout init --cone
git sparse-checkout set "ARCH AUTO INSTALL"
git checkout
chmod +x arch-install.sh
bash arch-install.sh

