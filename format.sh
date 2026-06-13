mkfs.fat -F32 /dev/nvme1n1p1
mkfs.btrfs -f /dev/nvme1n1p2
mkswap /dev/nvme1n1p3


# Monter la partition racine pour créer les sous-volumes
mount -o compress=zstd:4 /dev/nvme1n1p2 /mnt

# Créer les sous-volumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots

# Démonter /mnt
umount /mnt

# Monter les sous-volumes avec compression à leurs points de montage finaux
mount -o compress=zstd:4,subvol=@ /dev/nvme1n1p2 /mnt
mkdir -p /mnt/{home,var,.snapshots}
mount -o compress=zstd:4,subvol=@home /dev/nvme1n1p2 /mnt/home
mount -o compress=zstd:4,subvol=@var /dev/nvme1n1p2 /mnt/var
mount -o compress=zstd:4,subvol=@snapshots /dev/nvme1n1p2 /mnt/.snapshots                 # Monter l’EFI (n’oubliez pas)
mount --mkdir /dev/nvme1n1p1 /mnt/boot

# Activer le swap
swapon /dev/nvme1n1p3

pacstrap -K  /mnt base linux linux-firmware \
        btrfs-progs vim man-pages man-db texinfo \
        systemd efibootmgr networkmanager sudo \
        ufw openssh terminus-font noto-fonts-emoji --noconfirm

# Générer fstab avec UUID et options btrfs
echo "Génération de /mnt/etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Ajouter l'option compress=zstd:4 pour chaque ligne contenant subvol=@...
# (certaines lignes peuvent ne pas l'avoir si mount était sans compression)
#echo "Ajout de l'option compress=zstd:4 dans fstab..."
#sed -i 's/subvol=\([^,]*\)/compress=zstd:4,subvol=\1/g' /mnt/etc/fstab

# Optionnel : activer la défragmentation automatique en arrière-plan pour btrfs
# (cela aide à maintenir la compression sur les fichiers existants)
echo "Activation de la défragmentation automatique (sysctl)..."
mkdir -p /mnt/etc/sysctl.d
cat > /mnt/etc/sysctl.d/99-btrfs-autodefrag.conf << EOF
# Défragmentation automatique pour btrfs (améliore la compression des anciens fichiers)
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF

cp setup.sh /mnt/setup.sh

arch-chroot /mnt /bin/bash -c "./setup.sh"
