#!/bin/bash
# ============================================================================
# Interactive Arch Linux Installer – flexible, safe, user‑friendly
# ============================================================================
# No command‑line arguments needed. The script will guide you through:
#   - Disk selection (with optional full wipe)
#   - Root partition setup (existing partition or new one in free space)
#   - EFI partition detection/creation
#   - Filesystem type (ext4 / btrfs / xfs)
#   - LUKS encryption (optional)
#   - Hostname, root password, optional sudo user
#   - Services: NetworkManager, UFW, SSH (with secure defaults)
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ask()   { echo -e "${BLUE}[?]${NC} $1"; }

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------
confirm() {
    local prompt="$1 (y/N): "
    local default="${2:-n}"
    local answer
    read -r -p "$prompt" answer
    answer=${answer:-$default}
    [[ "$answer" =~ ^[Yy]$ ]]
}

select_from_list() {
    local title="$1"
    shift
    local options=("$@")
    echo "$title"
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    local choice
    while true; do
        read -r -p "Choice [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        fi
        warn "Invalid choice, try again."
    done
}

get_valid_size_gib() {
    local default_gib="$1"
    local min_gib=8
    local size_gib
    while true; do
        read -r -p "Root partition size in GiB (default $default_gib, min $min_gib): " size_gib
        size_gib=${size_gib:-$default_gib}
        if [[ "$size_gib" =~ ^[0-9]+$ ]] && (( size_gib >= min_gib )); then
            echo "$size_gib"
            return
        fi
        warn "Please enter a number ≥ ${min_gib}."
    done
}

# ----------------------------------------------------------------------------
# Step 1: Select disk
# ----------------------------------------------------------------------------
info "Scanning available disks..."
mapfile -t disks < <(lsblk -d -o NAME,SIZE,MODEL -n -e 7,11 | awk '{print "/dev/"$1" ("$2", "$3")"}')
if [[ ${#disks[@]} -eq 0 ]]; then
    error "No disks found."
fi
selected_disk=$(select_from_list "Available disks:" "${disks[@]}")
selected_disk=$(echo "$selected_disk" | cut -d' ' -f1)
info "Selected disk: $selected_disk"

# ----------------------------------------------------------------------------
# Step 2: Installation mode (whole disk vs existing partition)
# ----------------------------------------------------------------------------
mode=$(select_from_list "Installation mode:" \
    "Install on whole disk (will partition automatically)" \
    "Use an existing partition as root (keep other data)")

if [[ "$mode" == *"whole disk"* ]]; then
    WHOLE_DISK=true
    USE_EXISTING_ROOT=false
else
    WHOLE_DISK=false
    USE_EXISTING_ROOT=true
fi

# ----------------------------------------------------------------------------
# Step 3: For whole disk mode – optional wipe
# ----------------------------------------------------------------------------
WIPE_DISK=false
if [[ "$WHOLE_DISK" == true ]]; then
    if confirm "Do you want to WIPE the entire disk $selected_disk? (All data will be lost)"; then
        warn "ARE YOU ABSOLUTELY SURE? This will destroy ALL data on $selected_disk."
        if confirm "Type 'YES' to confirm wipe" "n"; then
            read -r confirm_wipe
            if [[ "$confirm_wipe" == "YES" ]]; then
                WIPE_DISK=true
                info "Disk will be wiped."
            else
                error "Wipe aborted by user."
            fi
        else
            info "Wipe cancelled – will try to use existing free space."
        fi
    fi
fi

# ----------------------------------------------------------------------------
# Step 4: Root partition selection/creation
# ----------------------------------------------------------------------------
if [[ "$USE_EXISTING_ROOT" == true ]]; then
    # List all partitions (non‑swap, size ≥ 8GiB)
    mapfile -t partitions < <(lsblk -l -o NAME,SIZE,TYPE -n | grep part | while read -r name size type; do
        size_bytes=$(lsblk -b -n -o SIZE "/dev/$name")
        size_gib=$(( size_bytes / 1024 / 1024 / 1024 ))
        if (( size_gib >= 8 )); then
            echo "/dev/$name ($size_gib GiB)"
        fi
    done)
    if [[ ${#partitions[@]} -eq 0 ]]; then
        error "No suitable partition (≥8 GiB) found."
    fi
    root_part=$(select_from_list "Select root partition (will be FORMATTED):" "${partitions[@]}")
    ROOT_PART=$(echo "$root_part" | cut -d' ' -f1)
    info "Will use $ROOT_PART as root (formatted)."
    # No need to create partitions, but we still need an EFI partition
    CREATE_ROOT_PART=false
else
    CREATE_ROOT_PART=true
    if [[ "$WIPE_DISK" == true ]]; then
        info "Wiping $selected_disk and creating fresh GPT..."
        parted "$selected_disk" mklabel gpt
        # Create 1GiB EFI
        parted "$selected_disk" mkpart primary fat32 1MiB 1025MiB
        parted "$selected_disk" set 1 esp on
        EFI_PART="${selected_disk}p1"
        # Root will be created after size input
    fi
fi

# ----------------------------------------------------------------------------
# Step 5: EFI partition handling
# ----------------------------------------------------------------------------
if [[ -z "${EFI_PART:-}" ]]; then
    # Detect existing ESP(s)
    mapfile -t efi_candidates < <(lsblk -l -o NAME,PARTTYPE,SIZE,LABEL -n | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print "/dev/"$1" ("$3", "$4")"}')
    if [[ ${#efi_candidates[@]} -gt 0 ]]; then
        ask "Found existing EFI system partition(s):"
        efi_options=("${efi_candidates[@]}" "Create a new EFI partition (on $selected_disk)" "No EFI partition (abort)")
        chosen=$(select_from_list "Select EFI partition to use:" "${efi_options[@]}")
        if [[ "$chosen" == "Create a new EFI partition"* ]]; then
            CREATE_EFI=true
        elif [[ "$chosen" == "No EFI partition"* ]]; then
            error "EFI partition required. Aborting."
        else
            BOOT_PART=$(echo "$chosen" | cut -d' ' -f1)
            info "Using existing EFI partition: $BOOT_PART"
            CREATE_EFI=false
        fi
    else
        warn "No EFI partition found on any disk."
        if confirm "Create a new 1GiB EFI partition on $selected_disk?"; then
            CREATE_EFI=true
        else
            error "Cannot proceed without EFI partition."
        fi
    fi
fi

# Create EFI if needed
if [[ "${CREATE_EFI:-false}" == true ]]; then
    # Ensure we are on the selected disk
    if [[ "$WHOLE_DISK" == true && "$WIPE_DISK" == true ]]; then
        # Already created during wipe, just assign
        EFI_PART="${selected_disk}p1"
    else
        info "Creating 1GiB EFI partition on $selected_disk from free space..."
        # Find free space (simplified: use the first free region)
        free_info=$(parted "$selected_disk" unit B print free 2>/dev/null | grep -i "Free Space" | head -1)
        if [[ -z "$free_info" ]]; then
            error "No free space on $selected_disk to create EFI partition."
        fi
        free_start=$(echo "$free_info" | awk '{print $1}' | sed 's/B//')
        efi_end_bytes=$(( $(echo "$free_start" | cut -d. -f1) + 1024*1024*1024 ))
        efi_end="${efi_end_bytes}B"
        parted "$selected_disk" mkpart primary fat32 "${free_start}B" "$efi_end"
        parted "$selected_disk" set 1 esp on
        sleep 2
        # The new partition is usually the last one
        EFI_PART=$(lsblk -l -o NAME,MAJ:MIN "$selected_disk" | grep -v "^NAME" | sort -k2 -n | tail -1 | awk '{print "/dev/"$1}')
    fi
    BOOT_PART="$EFI_PART"
    info "Created EFI partition: $BOOT_PART"
    mkfs.fat -F32 "$BOOT_PART"
fi

# ----------------------------------------------------------------------------
# Step 6: Root partition creation/sizing (if needed)
# ----------------------------------------------------------------------------
if [[ "$CREATE_ROOT_PART" == true ]]; then
    # Determine free space
    free_info=$(parted "$selected_disk" unit B print free 2>/dev/null | grep -i "Free Space")
    if [[ -z "$free_info" ]]; then
        error "No free space on $selected_disk for root partition."
    fi
    # Use the largest free region (last one)
    free_start=$(echo "$free_info" | tail -1 | awk '{print $1}' | sed 's/B//')
    free_end=$(echo "$free_info" | tail -1 | awk '{print $2}' | sed 's/B//')
    free_bytes=$(( $(echo "$free_end" | cut -d. -f1) - $(echo "$free_start" | cut -d. -f1) ))
    free_gib=$(( free_bytes / 1024 / 1024 / 1024 ))
    info "Available free space: ~${free_gib} GiB"

    default_size_gib=$free_gib
    if (( default_size_gib < 8 )); then
        error "Not enough free space (${free_gib} GiB) – need at least 8 GiB."
    fi
    root_size_gib=$(get_valid_size_gib "$default_size_gib")
    if (( root_size_gib > free_gib )); then
        error "Requested ${root_size_gib} GiB, only ${free_gib} GiB available."
    fi

    requested_bytes=$(( root_size_gib * 1024 * 1024 * 1024 ))
    target_end_bytes=$(( $(echo "$free_start" | cut -d. -f1) + requested_bytes ))
    target_end="${target_end_bytes}B"
    root_start="${free_start}B"

    info "Creating root partition from $root_start to $target_end"
    parted "$selected_disk" mkpart primary ext4 "$root_start" "$target_end"
    sleep 2
    ROOT_PART=$(lsblk -l -o NAME,MAJ:MIN "$selected_disk" | grep -v "^NAME" | sort -k2 -n | tail -1 | awk '{print "/dev/"$1}')
    info "Root partition created: $ROOT_PART"
fi

# ----------------------------------------------------------------------------
# Step 7: Filesystem type and encryption
# ----------------------------------------------------------------------------
fs_type=$(select_from_list "Filesystem for root:" "ext4" "btrfs" "xfs")
if confirm "Encrypt root partition with LUKS?"; then
    USE_LUKS=true
    info "Setting up LUKS encryption on $ROOT_PART"
    cryptsetup luksFormat --type luks2 "$ROOT_PART"
    cryptsetup open "$ROOT_PART" cryptroot
    ROOT_MAPPER="/dev/mapper/cryptroot"
else
    USE_LUKS=false
    ROOT_MAPPER="$ROOT_PART"
fi

# Format
case "$fs_type" in
    ext4) mkfs.ext4 -F "$ROOT_MAPPER" ;;
    btrfs) mkfs.btrfs -f "$ROOT_MAPPER" ;;
    xfs) mkfs.xfs -f "$ROOT_MAPPER" ;;
esac

# ----------------------------------------------------------------------------
# Step 8: Mount partitions
# ----------------------------------------------------------------------------
info "Mounting root to /mnt"
mount "$ROOT_MAPPER" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# ----------------------------------------------------------------------------
# Step 9: Install base system
# ----------------------------------------------------------------------------
info "Installing base packages (this may take a few minutes)..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware \
    networkmanager sudo openssh ufw vim man-db man-pages texinfo reflector \
    || error "pacstrap failed"

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# ----------------------------------------------------------------------------
# Step 10: Chroot configuration
# ----------------------------------------------------------------------------
info "Configuring system (chroot)..."

# Build chroot commands as array to conditionally include steps
chroot_commands=(
    "echo 'KEYMAP=fr' > /etc/vconsole.conf"
    "ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime"
    "hwclock --systohc"
    "echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen"
    "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"
)

# Hostname
read -r -p "Hostname [archlinux]: " hostname
hostname=${hostname:-archlinux}
chroot_commands+=("echo '$hostname' > /etc/hostname")
chroot_commands+=("cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS")

# Root password
if confirm "Set root password? (otherwise default is 'root')"; then
    chroot_commands+=("passwd")
else
    warn "Root password will be 'root' – please change after first login."
    chroot_commands+=("echo 'root:root' | chpasswd")
fi

# Sudo user
if confirm "Create a sudo user (recommended)?"; then
    read -r -p "Username: " username
    while [[ -z "$username" ]]; do
        warn "Username cannot be empty."
        read -r -p "Username: " username
    done
    chroot_commands+=("useradd -m -G wheel -s /bin/bash $username")
    chroot_commands+=("passwd $username")
    chroot_commands+=("echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers")
fi

# Services
chroot_commands+=("systemctl enable NetworkManager")
if confirm "Enable UFW firewall (allow SSH)?"; then
    chroot_commands+=("ufw default deny incoming && ufw default allow outgoing && ufw allow ssh && ufw --force enable && systemctl enable ufw")
fi
if confirm "Enable SSH server (secure: no root login, no password auth)?"; then
    chroot_commands+=("systemctl enable sshd")
    chroot_commands+=("sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config")
    chroot_commands+=("sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config")
    chroot_commands+=("systemctl restart sshd")
fi

# systemd-boot
chroot_commands+=("bootctl install")
# Determine root PARTUUID (for LUKS we need the UUID of the physical partition or mapper?)
if [[ "$USE_LUKS" == true ]]; then
    # For LUKS: kernel option should point to the physical partition, then cryptroot unlocks
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    chroot_commands+=("cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options cryptdevice=UUID=$root_uuid:cryptroot root=/dev/mapper/cryptroot rw
ENTRY")
    # Add mkinitcpio hook for encryption
    chroot_commands+=("sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf")
    chroot_commands+=("mkinitcpio -p linux")
else
    root_partuuid=$(blkid -s PARTUUID -o value "$ROOT_PART")
    chroot_commands+=("cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$root_partuuid rw
ENTRY")
fi
chroot_commands+=("echo 'default arch.conf' > /boot/loader/loader.conf")

# Pacman optimizations
chroot_commands+=("sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf")
chroot_commands+=("echo -e '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist' >> /etc/pacman.conf")
chroot_commands+=("reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist")

# Execute commands in chroot
for cmd in "${chroot_commands[@]}"; do
    arch-chroot /mnt /bin/bash -c "$cmd"
done

# ----------------------------------------------------------------------------
# Step 11: Cleanup and finish
# ----------------------------------------------------------------------------
umount -R /mnt
if [[ "$USE_LUKS" == true ]]; then
    cryptsetup close cryptroot
fi

info "==========================================="
info "Installation complete! You can reboot now."
info "==========================================="
info "  - Keyboard layout: fr (AZERTY)"
info "  - Bootloader: systemd-boot"
if [[ "$USE_LUKS" == true ]]; then
    info "  - Encryption: LUKS (you will be prompted for password at boot)"
fi
exit 0
