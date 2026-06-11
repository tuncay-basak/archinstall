#!/bin/bash
# ============================================================================
# Arch Linux Installer – flexible, no unwanted wipes
# ============================================================================
# Usage:
#   --disk /dev/nvmeXnY [--size 64GiB] [--boot /dev/efi_part] [--wipe] [--name hostname]
#   --partition /dev/nvmeXnYpZ [--boot /dev/efi_part] [--name hostname]
#
#   Exactly one of --disk or --partition.
#   --wipe only allowed with --disk (wipes the whole disk after confirmation).
#   --boot optional: if not given, script auto-detects existing ESP,
#       or creates one from free space on --disk (if possible).
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ask()   { echo -e "${YELLOW}[QUESTION]${NC} $1"; }

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
DISK=""
PARTITION=""
BOOT_PART=""
ROOT_SIZE=""
HOSTNAME="archlinux"
WIPE_FLAG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)       DISK="$2";        shift 2 ;;
        --partition)  PARTITION="$2";   shift 2 ;;
        --boot)       BOOT_PART="$2";   shift 2 ;;
        --size)       ROOT_SIZE="$2";   shift 2 ;;
        --name)       HOSTNAME="$2";    shift 2 ;;
        --wipe)       WIPE_FLAG=true;   shift 1 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Exactly one of --disk or --partition
if [[ -n "$DISK" && -n "$PARTITION" ]]; then
    error "Cannot specify both --disk and --partition."
fi
if [[ -z "$DISK" && -z "$PARTITION" ]]; then
    error "Must specify either --disk or --partition."
fi

# --wipe only with --disk
if [[ "$WIPE_FLAG" == true && -z "$DISK" ]]; then
    error "--wipe can only be used with --disk."
fi

# Validate disk/partition
if [[ -n "$DISK" ]]; then
    [[ -b "$DISK" ]] || error "Disk $DISK does not exist."
    info "Target disk (for root): $DISK"
    if [[ -n "$ROOT_SIZE" ]]; then
        if [[ ! "$ROOT_SIZE" =~ ^[0-9]+GiB$ ]]; then
            error "Invalid --size format. Use like '64GiB'."
        fi
        size_num=${ROOT_SIZE%GiB}
        if [[ $size_num -lt 8 ]]; then
            error "Root size must be at least 8 GiB (you asked for ${size_num}GiB)."
        fi
        info "Requested root size: $ROOT_SIZE"
    else
        info "Root size: all free space on $DISK (or whole disk if --wipe)"
    fi
else
    # --partition
    [[ -b "$PARTITION" ]] || error "Partition $PARTITION does not exist."
    part_size_bytes=$(lsblk -b -no SIZE "$PARTITION" 2>/dev/null || echo 0)
    part_size_gib=$(( part_size_bytes / 1024 / 1024 / 1024 ))
    if [[ $part_size_gib -lt 8 ]]; then
        error "Partition $PARTITION is only ${part_size_gib}GiB, need at least 8GiB."
    fi
    info "Using existing partition $PARTITION (${part_size_gib}GiB) as root (will be formatted)."
    if [[ -n "$ROOT_SIZE" ]]; then
        warn "--size ignored when --partition is used."
    fi
fi

# ----------------------------------------------------------------------------
# French keyboard for live session
# ----------------------------------------------------------------------------
info "Setting French keyboard layout (fr) for live environment"
loadkeys fr

# ----------------------------------------------------------------------------
# Handle --wipe (only with --disk)
# ----------------------------------------------------------------------------
if [[ "$WIPE_FLAG" == true ]]; then
    warn "You requested --wipe. This will DESTROY ALL DATA on $DISK."
    ask "Type 'YES' to confirm wipe: "
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        error "Wipe aborted."
    fi
    info "Wiping $DISK, creating fresh GPT..."
    parted "$DISK" mklabel gpt
    info "Creating 1GiB EFI partition as ${DISK}p1"
    parted "$DISK" mkpart primary fat32 1MiB 1025MiB
    parted "$DISK" set 1 esp on
    # Create root partition
    if [[ -n "$ROOT_SIZE" ]]; then
        size_mib=$((size_num * 1024))
        root_end=$((1025 + size_mib))
        info "Creating root partition of exactly $ROOT_SIZE (ends at ${root_end}MiB)"
        parted "$DISK" mkpart primary ext4 1025MiB ${root_end}MiB
    else
        info "Creating root partition using remaining space"
        parted "$DISK" mkpart primary ext4 1025MiB 100%
    fi
    sleep 2
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
    [[ -b "$EFI_PART" ]] || error "EFI partition not created"
    [[ -b "$ROOT_PART" ]] || error "Root partition not created"
    info "Formatting EFI partition (FAT32)..."
    mkfs.fat -F32 "$EFI_PART"
    info "Formatting root partition (ext4)..."
    mkfs.ext4 -F "$ROOT_PART"
    # Set boot partition to the newly created one
    BOOT_PART="$EFI_PART"
    # Skip the rest of EFI detection and root creation
    SKIP_ROOT_CREATION=true
fi

# ----------------------------------------------------------------------------
# If not --wipe, handle EFI detection and root creation
# ----------------------------------------------------------------------------
if [[ "$WIPE_FLAG" != true ]]; then
    # ---------- EFI partition determination ----------
    if [[ -n "$BOOT_PART" ]]; then
        # User provided
        [[ -b "$BOOT_PART" ]] || error "Boot partition $BOOT_PART does not exist."
        boot_fstype=$(lsblk -no FSTYPE "$BOOT_PART" 2>/dev/null || echo "")
        if [[ "$boot_fstype" != "vfat" ]]; then
            error "Boot partition $BOOT_PART has filesystem '$boot_fstype', must be FAT32."
        fi
        info "Using user-provided EFI partition: $BOOT_PART"
    else
        # Auto-detect existing EFI partition
        EFI_CANDIDATES=()
        # First, if --disk is used, check if it has an ESP
        if [[ -n "$DISK" ]]; then
            mapfile -t disk_efis < <(lsblk -l -o NAME,PARTTYPE "$DISK" 2>/dev/null | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print "/dev/"$1}' || true)
            if [[ ${#disk_efis[@]} -gt 0 ]]; then
                EFI_CANDIDATES+=("${disk_efis[@]}")
            fi
        fi
        # If none on --disk, scan all disks
        if [[ ${#EFI_CANDIDATES[@]} -eq 0 ]]; then
            mapfile -t all_efis < <(lsblk -l -o NAME,PARTTYPE 2>/dev/null | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print "/dev/"$1}' || true)
            EFI_CANDIDATES+=("${all_efis[@]}")
        fi

        if [[ ${#EFI_CANDIDATES[@]} -gt 0 ]]; then
            info "Found existing EFI partition(s): ${EFI_CANDIDATES[*]}"
            # Use the first one, ask user
            ask "Use ${EFI_CANDIDATES[0]} as EFI partition? (y/N): "
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                BOOT_PART="${EFI_CANDIDATES[0]}"
                info "Using $BOOT_PART as EFI partition."
            else
                error "No EFI partition selected. Aborting."
            fi
        else
            # No EFI found anywhere. If --disk is given, create one from free space
            if [[ -n "$DISK" ]]; then
                info "No existing EFI partition found. Will create a 1GiB EFI partition from free space on $DISK."
                # Check if there is at least 1GiB free space on $DISK
                free_info=$(parted "$DISK" unit B print free 2>/dev/null | grep -i "Free Space")
                if [[ -z "$free_info" ]]; then
                    error "No free space on $DISK to create EFI partition."
                fi
                # Find the largest free region (take the last one for simplicity)
                free_start=$(echo "$free_info" | tail -1 | awk '{print $1}' | sed 's/B//')
                free_end=$(echo "$free_info" | tail -1 | awk '{print $2}' | sed 's/B//')
                free_bytes=$(( $(echo "$free_end" | cut -d. -f1) - $(echo "$free_start" | cut -d. -f1) ))
                free_gib=$(( free_bytes / 1024 / 1024 / 1024 ))
                if [[ $free_gib -lt 1 ]]; then
                    error "Not enough free space (need at least 1GiB, have ~${free_gib}GiB)."
                fi
                # Create EFI partition of 1GiB at the beginning of the free region
                efi_end_bytes=$(( $(echo "$free_start" | cut -d. -f1) + 1024*1024*1024 ))
                efi_end="${efi_end_bytes}B"
                info "Creating EFI partition from ${free_start}B to $efi_end"
                parted "$DISK" mkpart primary fat32 "${free_start}B" "$efi_end"
                parted "$DISK" set 1 esp on   # assuming it becomes p1 (may not be p1 if other partitions exist)
                sleep 2
                # Determine the new partition name
                # It's usually the last partition on the disk
                NEW_EFI=$(lsblk -l -o NAME,MAJ:MIN "$DISK" | grep -v "^NAME" | sort -k2 -n | tail -1 | awk '{print "/dev/"$1}')
                BOOT_PART="$NEW_EFI"
                info "Created EFI partition: $BOOT_PART"
                mkfs.fat -F32 "$BOOT_PART"
            else
                error "No EFI partition found and --disk not provided (cannot create one). Aborting."
            fi
        fi
    fi

    # ---------- Root partition creation (if --disk and not wiped) ----------
    if [[ -n "$DISK" ]]; then
        info "Analyzing free space on $DISK for root partition..."
        # Get free space after possibly creating EFI partition
        free_info=$(parted "$DISK" unit B print free 2>/dev/null | grep -i "Free Space")
        if [[ -z "$free_info" ]]; then
            error "No free space found on $DISK. Cannot create root partition."
        fi
        # Take the largest free region (simplified: last one)
        free_start=$(echo "$free_info" | tail -1 | awk '{print $1}' | sed 's/B//')
        free_end=$(echo "$free_info" | tail -1 | awk '{print $2}' | sed 's/B//')
        free_bytes=$(( $(echo "$free_end" | cut -d. -f1) - $(echo "$free_start" | cut -d. -f1) ))
        free_gib=$(( free_bytes / 1024 / 1024 / 1024 ))
        info "Available free space: ~${free_gib} GiB"

        if [[ -n "$ROOT_SIZE" ]]; then
            requested_bytes=$(( size_num * 1024 * 1024 * 1024 ))
            if [[ $requested_bytes -gt $free_bytes ]]; then
                error "Not enough free space. Requested ${size_num}GiB, only ~${free_gib}GiB available."
            fi
            target_end_bytes=$(( $(echo "$free_start" | cut -d. -f1) + requested_bytes ))
            target_end="${target_end_bytes}B"
            root_start="${free_start}B"
        else
            root_start="${free_start}B"
            target_end="${free_end}B"
        fi

        info "Creating root partition from $root_start to $target_end"
        parted "$DISK" mkpart primary ext4 "$root_start" "$target_end"
        sleep 2
        ROOT_PART=$(lsblk -l -o NAME,MAJ:MIN "$DISK" | grep -v "^NAME" | sort -k2 -n | tail -1 | awk '{print "/dev/"$1}')
        info "Root partition created: $ROOT_PART"
        mkfs.ext4 -F "$ROOT_PART"
    else
        # --partition case: already set ROOT_PART
        ROOT_PART="$PARTITION"
        info "Formatting existing partition $ROOT_PART as ext4"
        ask "Are you sure you want to format $ROOT_PART? (y/N): "
        read -r format_confirm
        if [[ ! "$format_confirm" =~ ^[Yy]$ ]]; then
            error "Aborted by user."
        fi
        mkfs.ext4 -F "$ROOT_PART"
    fi
fi

# ----------------------------------------------------------------------------
# Mount partitions
# ----------------------------------------------------------------------------
info "Mounting root partition ($ROOT_PART) to /mnt"
mount "$ROOT_PART" /mnt

info "Mounting EFI partition ($BOOT_PART) to /mnt/boot"
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# ----------------------------------------------------------------------------
# Install base system
# ----------------------------------------------------------------------------
info "Installing base packages (may take a few minutes)..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware \
    networkmanager sudo openssh ufw systemd \
    vim man-db man-pages texinfo nano reflector \
    || error "pacstrap failed"

# ----------------------------------------------------------------------------
# Generate fstab
# ----------------------------------------------------------------------------
info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# ----------------------------------------------------------------------------
# Chroot configuration
# ----------------------------------------------------------------------------
info "Entering chroot to configure the system"

arch-chroot /mnt /bin/bash <<EOF

# French keyboard (persistent)
echo "KEYMAP=fr" > /etc/vconsole.conf

# Timezone (adjust as needed)
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Temporary root password (CHANGE AFTER REBOOT)
echo "root:root" | chpasswd

# Sudo: wheel group
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# ufw firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
systemctl enable ufw

# --------------------------------------------------------------------
# systemd-boot installation
# --------------------------------------------------------------------
bootctl install

# Create loader entry for Arch
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART") rw
ENTRY

# Set default entry
echo "default arch.conf" > /boot/loader/loader.conf

# --------------------------------------------------------------------
# Optimizations
# --------------------------------------------------------------------
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

EOF

# ----------------------------------------------------------------------------
# Unmount and finish
# ----------------------------------------------------------------------------
info "Configuration finished. Unmounting..."
umount -R /mnt

info "==========================================="
info "Installation complete!"
info "You can now reboot."
info ""
info "First login: root / root"
info "IMPORTANT: Change root password immediately: passwd"
info ""
info "Keyboard: fr (AZERTY)"
info "Firewall: ufw enabled, SSH allowed"
info "Bootloader: systemd-boot"
info "==========================================="

exit 0
