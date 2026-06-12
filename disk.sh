#!/bin/bash

# Exit on error, undefined var, pipe failure
set -euo pipefail

DEVICE="/dev/nvme0n1"
EFI_SIZE="1GiB"
ROOT_SIZE="443GiB"
SWAP_SIZE="32GiB"

echo "=== Arch Linux partition & btrfs setup script ==="
echo "Target device: $DEVICE"
echo "This will DESTROY all data on $DEVICE"
read -p "Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# 1. Partitioning with parted
echo "=== Creating partitions ==="
parted "$DEVICE" -- mklabel gpt \
    mkpart primary fat32 1MiB "$EFI_SIZE" \
    set 1 boot on \
    mkpart primary btrfs "$EFI_SIZE" "$ROOT_SIZE" \
    mkpart primary linux-swap "$ROOT_SIZE" 100%

# Wait for kernel to recognize new partitions
sleep 2
partprobe "$DEVICE"

# 2. Format partitions
echo "=== Formatting ==="
mkfs.fat -F32 "${DEVICE}p1"
mkfs.btrfs -f "${DEVICE}p2"
mkswap "${DEVICE}p3"
swapon "${DEVICE}p3"

# 3. Create btrfs subvolumes
echo "=== Creating btrfs subvolumes ==="
mount "${DEVICE}p2" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 4. Mount subvolumes for installation
echo "=== Mounting subvolumes ==="
mount -o compress=zstd,subvol=@ "${DEVICE}p2" /mnt
mkdir -p /mnt/{home,var,.snapshots,boot}
mount -o compress=zstd,subvol=@home "${DEVICE}p2" /mnt/home
mount -o compress=zstd,subvol=@var "${DEVICE}p2" /mnt/var
mount -o compress=zstd,subvol=@snapshots "${DEVICE}p2" /mnt/.snapshots
mount "${DEVICE}p1" /mnt/boot

echo "=== Done ==="
lsblk "$DEVICE"
echo "Subvolumes:"
btrfs subvolume list /mnt
