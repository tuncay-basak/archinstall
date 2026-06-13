# --- Demande d'informations à l'utilisateur ---
read -p "Nom d'hôte (hostname) : " HOSTNAME
while true; do
    echo -n "Mot de passe root : "
    read -s ROOT_PASS
    echo
    echo -n "Confirmation : "                                                                 read -s ROOT_PASS2
    echo
    if [ "$ROOT_PASS" = "$ROOT_PASS2" ] && [ -n "$ROOT_PASS" ]; then
        break
    else
        echo "Erreur : les mots de passe ne correspondent pas ou sont vides."
    fi
done

# --- Mise à jour du système et installation des paquets manquants ---
pacman -Syu --noconfirm

# --- Clavier français au démarrage ---
echo "KEYMAP=fr" > /etc/vconsole.conf
echo "FONT=ter-124n" >> /etc/vconsole.conf   # police avec emojis (terminus)

# --- Locales ---
sed -i 's/^#\(fr_FR.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf

# --- Hostname ---
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# --- Mot de passe root ---
echo "root:$ROOT_PASS" | chpasswd

# --- Firewall (UFW) ---
ufw default deny
ufw allow ssh
ufw --force enable
systemctl enable ufw

# --- SSH ---
systemctl enable sshd

# --- NetworkManager ---
systemctl enable NetworkManager

# --- Sudo (groupe wheel) ---
sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers

# --- 1. Installer systemd-boot ---
echo "Installation de systemd-boot sur l'ESP..."
bootctl install

# --- 2. Récupérer l'UUID de la partition racine (nvme1n1p2) ---
ROOT_UUID=$(blkid -s UUID -o value /dev/nvme1n1p2)

# --- 3. Créer l'entrée normale (@) ---
cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@ compress=zstd:4 quiet loglevel=3
EOF

# --- 4. Gérer le snapshot readonly de @ vers @recovery ---
# On monte temporairement le btrfs root (subvolid=5) pour manipuler les sous-volumes
mkdir -p /mnt/btrfs-root
mount -o subvolid=5 /dev/nvme1n1p2 /mnt/btrfs-root

# Créer un snapshot readonly de @ vers @recovery
echo "Création d'un snapshot readonly de @ vers @recovery..."
btrfs subvolume snapshot -r /mnt/btrfs-root/@ /mnt/btrfs-root/@recovery

# On démonte
umount /mnt/btrfs-root
rmdir /mnt/btrfs-root

# --- 5. Créer l'entrée recovery (lecture seule) ---
# Note : le snapshot est readonly, donc on passe `ro` au noyau
cat > /boot/loader/entries/recovery.conf << EOF
title   Arch Linux Recovery (readonly)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID ro rootflags=subvol=@recovery compress=zstd:4 quiet loglevel=3 systemd.unit=rescue.target
EOF

# --- 6. Option : copier le noyau et initramfs actuels pour le recovery ---
# (ils sont déjà partagés, car sous /boot commun ; pas besoin de copie)

# --- 7. Définir le délai de démarrage (menu visible) ---
mkdir -p /boot/loader/conf.d
cat > /boot/loader/conf.d/loader.conf << EOF
default arch.conf
timeout 5
editor   no
EOF

echo "✅ Configuration terminée."
echo "▶ Vous pouvez maintenant redémarrer (exit, umount -R /mnt, reboot)"
