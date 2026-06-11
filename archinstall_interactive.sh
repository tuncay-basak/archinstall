#!/bin/bash

# -----------------------------------------------------------------------------
# Arch Linux Automated Installer (systemd-boot, LUKS, French keymap)
# Fixed: LUKS hook consistency, SSH sed, parted relative sizes, wipe loop,
#        password injection, ESP reformat warning
# -----------------------------------------------------------------------------

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/tmp/arch_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
error() { echo -e "${RED}ERROR: $*${NC}" >&2; }
warn() { echo -e "${YELLOW}WARNING: $*${NC}"; }
info() { echo -e "${CYAN}INFO: $*${NC}"; }
success() { echo -e "${GREEN}SUCCESS: $*${NC}"; }

ask_yes_no() {
    local prompt="$1" default="${2:-}" answer
    while true; do
        if [[ "$default" == "yes" ]]; then
            read -rp "$prompt [Y/n]: " answer
            answer=${answer:-Y}
        elif [[ "$default" == "no" ]]; then
            read -rp "$prompt [y/N]: " answer
            answer=${answer:-N}
        else
            read -rp "$prompt [y/n]: " answer
        fi
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

confirm() {
    local prompt="$1" answer
    read -rp "$prompt (type 'yes' to confirm): " answer
    [[ "$answer" == "yes" ]]
}

# -----------------------------------------------------------------------------
# Partition naming fix
# -----------------------------------------------------------------------------
get_partition_path() {
    local disk="$1" part_num="$2"
    local disk_name="${disk##*/}"
    if [[ "$disk_name" =~ [0-9]$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

wait_for_partition() {
    local part_path="$1"
    for i in {1..10}; do
        if [[ -b "$part_path" ]]; then
            return 0
        fi
        sleep 0.5
    done
    error "Partition $part_path did not appear after creation."
    return 1
}

# -----------------------------------------------------------------------------
# 1. Select disk
# -----------------------------------------------------------------------------
info "Detecting available disks..."
disks=($(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}'))
if [[ ${#disks[@]} -eq 0 ]]; then
    error "No disks found!"
    exit 1
fi

echo -e "${BLUE}Available disks:${NC}"
select disk in "${disks[@]}"; do
    if [[ -n "$disk" ]]; then
        success "Selected disk: $disk"
        break
    else
        echo "Invalid choice. Please select a number."
    fi
done

# -----------------------------------------------------------------------------
# 2. Ensure EFI partition exists (create if missing)
# -----------------------------------------------------------------------------
efi_part=""
ensure_efi_partition() {
    local disk="$1"
    local efi_test="$(get_partition_path "$disk" 1)"
    if [[ -b "$efi_test" ]]; then
        local part_type
        part_type=$(blkid -o value -s PARTTYPE "$efi_test" 2>/dev/null || echo "")
        if [[ "$part_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
            info "EFI System Partition found on ${efi_test}."
            efi_part="$efi_test"
            return 0
        fi
    fi
    warn "No EFI System Partition found on ${efi_test}."
    echo "UEFI firmware requires an EFI partition (FAT32, type EF00) to boot."
    echo "The only safe option is to wipe the disk and create a proper GPT layout."
    if confirm "Wipe entire disk $disk and create a new partition table?"; then
        info "Wiping disk $disk..."
        wipefs -a "$disk"
        parted -s "$disk" mklabel gpt
        # Ask for EFI size
        default_efi_size="1GiB"
        while true; do
            read -rp "EFI partition size (default $default_efi_size, minimum 128MiB): " efi_size
            efi_size=${efi_size:-$default_efi_size}
            if [[ "$efi_size" =~ ^[0-9]+MiB$ ]]; then
                size_mib=${efi_size%MiB}
                if [[ $size_mib -ge 128 ]]; then
                    break
                else
                    error "Size must be at least 128MiB."
                fi
            elif [[ "$efi_size" =~ ^[0-9]+GiB$ ]]; then
                break
            else
                error "Invalid format. Use e.g. 512MiB, 1GiB."
            fi
        done
        info "Creating EFI partition (size $efi_size)..."
        parted -s "$disk" mkpart primary fat32 1MiB "$efi_size"
        parted -s "$disk" set 1 esp on
        partprobe "$disk"
        efi_part="$(get_partition_path "$disk" 1)"
        wait_for_partition "$efi_part"
        success "EFI partition created: $efi_part"
        return 0
    else
        error "Cannot proceed without a valid EFI partition. Exiting."
        exit 1
    fi
}

ensure_efi_partition "$disk"

# -----------------------------------------------------------------------------
# 3. Root partition selection (with wipe as an option, proper size handling)
# -----------------------------------------------------------------------------
root_part=""
while [[ -z "$root_part" ]]; do
    echo -e "${BLUE}Root partition selection:${NC}"
    existing_parts=()
    # List all partitions except the EFI one (p1)
    for part_num in $(seq 2 20); do
        part_path="$(get_partition_path "$disk" "$part_num")"
        if [[ -b "$part_path" ]] && ! mount | grep -q "$part_path"; then
            size_bytes=$(blockdev --getsize64 "$part_path" 2>/dev/null || echo 0)
            if [[ $size_bytes -ge $((8*1024*1024*1024)) ]]; then
                existing_parts+=("$part_path")
            fi
        fi
    done
    # Check free unallocated space (≥8GiB)
    free_space_bytes=$(parted -s "$disk" unit b print free | awk '/Free Space/ {gsub("B","",$3); sum+=$3} END {print sum}')
    free_ge_8gb=$((free_space_bytes >= 8*1024*1024*1024))

    PS3="Select an option: "
    options=()
    if [[ "$free_ge_8gb" == "1" ]]; then
        options+=("Create new partition in free space (≥8GiB available)")
    fi
    for part in "${existing_parts[@]}"; do
        size_gb=$(lsblk -dn -o SIZE "$part" | awk '{print $1}')
        options+=("Use existing partition $part (size $size_gb)")
    done
    options+=("Wipe entire disk and start fresh (strong confirm required)")

    select opt in "${options[@]}"; do
        case $opt in
            "Create new partition in free space (≥8GiB available)")
                default_size="all"
                read -rp "Size for new partition (default $default_size, e.g. 20G, +8G): " part_size
                part_size=${part_size:-$default_size}
                # Convert to relative size for parted
                if [[ "$part_size" == "all" ]] || [[ "$part_size" == "100%" ]]; then
                    size_arg="100%"
                else
                    # If it doesn't start with '+', add it
                    if [[ "$part_size" != +* ]]; then
                        size_arg="+$part_size"
                    else
                        size_arg="$part_size"
                    fi
                fi
                # Récupérer la fin de la partition EFI (p1) comme début
start=$(parted -s "$disk" print | awk '/^ 1 / {print $3}')
if [[ "$size_arg" == "100%" ]]; then
    parted -s "$disk" mkpart primary "$start" 100%
else
    parted -s "$disk" mkpart primary "$start" "$size_arg"
fi
                partprobe "$disk"
                sleep 1
                new_part_num=$(parted -s "$disk" print | awk '/^ [0-9]+/ {print $1}' | tail -1)
                root_part="$(get_partition_path "$disk" "$new_part_num")"
                wait_for_partition "$root_part"
                success "New root partition created: $root_part"
                break 2  # sort du select et de la boucle while (root_part est défini)
                ;;
            "Use existing partition"*)
                root_part=$(echo "$opt" | awk '{print $4}')
                if mount | grep -q "$root_part"; then
                    error "Partition $root_part is currently mounted. Please choose another."
                    continue
                fi
                success "Using existing partition $root_part as root."
                break 2
                ;;
            "Wipe entire disk and start fresh (strong confirm required)")
                echo -e "${RED}WARNING: This will erase all data on $disk, including the existing EFI partition.${NC}"
                total_bytes=$(blockdev --getsize64 "$disk")
                if [[ $total_bytes -lt $((9*1024*1024*1024)) ]]; then
                    error "Disk smaller than 9GiB. Need at least 8GiB for root + EFI."
                    continue
                fi
                if confirm "Type 'yes' to PERMANENTLY WIPE $disk"; then
                    # Wipe and recreate GPT
                    wipefs -a "$disk"
                    parted -s "$disk" mklabel gpt
                    # Recreate EFI partition
                    while true; do
                        read -rp "EFI partition size (default 1GiB, min 128MiB): " efi_size
                        efi_size=${efi_size:-1GiB}
                        if [[ "$efi_size" =~ ^[0-9]+MiB$ ]]; then
                            [[ ${efi_size%MiB} -ge 128 ]] && break
                        elif [[ "$efi_size" =~ ^[0-9]+GiB$ ]]; then
                            break
                        else
                            error "Invalid format."
                        fi
                    done
                    parted -s "$disk" mkpart primary fat32 1MiB "$efi_size"
                    parted -s "$disk" set 1 esp on
                    partprobe "$disk"
                    efi_part="$(get_partition_path "$disk" 1)"
                    wait_for_partition "$efi_part"
                    success "EFI partition recreated: $efi_part"
                    # Maintenant, on sort du select (break) mais pas du while,
                    # car root_part est toujours vide. La boucle while va répéter
                    # l'affichage du menu, où l'espace libre sera détecté.
                    break  # <--- Correction : sort uniquement du select
                else
                    echo "Aborted wipe. Choose another option."
                    continue
                fi
                ;;
            *) echo "Invalid option" ;;
        esac
    done
done

info "EFI partition: $efi_part"
info "Root partition: $root_part"

# -----------------------------------------------------------------------------
# 4. LUKS encryption
# -----------------------------------------------------------------------------
if ask_yes_no "Do you want to encrypt the root partition with LUKS?" no; then
    luks=true
    while true; do
        read -rsp "Enter LUKS passphrase: " luks_pass
        echo
        read -rsp "Confirm LUKS passphrase: " luks_pass2
        echo
        if [[ "$luks_pass" == "$luks_pass2" && -n "$luks_pass" ]]; then
            break
        else
            error "Passphrases do not match or are empty. Try again."
        fi
    done
else
    luks=false
fi

# -----------------------------------------------------------------------------
# 5. Filesystem format
# -----------------------------------------------------------------------------
echo -e "${BLUE}Select root filesystem:${NC}"
fs_options=("ext4" "btrfs" "xfs" "f2fs")
select fs in "${fs_options[@]}"; do
    if [[ -n "$fs" ]]; then
        success "Using $fs"
        break
    else
        echo "Invalid choice."
    fi
done

# Avertissement avant de reformater l'ESP si elle existait déjà
if [[ -b "$efi_part" ]]; then
    warn "The existing EFI partition $efi_part will be formatted (FAT32). Any existing bootloaders will be erased."
    if ! ask_yes_no "Continue?" yes; then
        error "User aborted."
        exit 1
    fi
fi
info "Formatting EFI partition..."
mkfs.fat -F32 "$efi_part"

if [[ "$luks" == true ]]; then
    info "Setting up LUKS on $root_part..."
    # Utilisation de --key-file=- pour éviter que le passphrase n'apparaisse dans /proc
    echo -n "$luks_pass" | cryptsetup luksFormat --type luks2 --key-file=- "$root_part"
    echo -n "$luks_pass" | cryptsetup open --key-file=- "$root_part" cryptroot
    root_mapper="/dev/mapper/cryptroot"
    info "Formatting encrypted volume as $fs..."
    mkfs."$fs" "$root_mapper"
else
    root_mapper="$root_part"
    info "Formatting $root_part as $fs..."
    mkfs."$fs" "$root_part"
fi

# -----------------------------------------------------------------------------
# 6. Mount and pacstrap
# -----------------------------------------------------------------------------
info "Mounting root partition..."
mount "$root_mapper" /mnt
mkdir -p /mnt/boot
mount "$efi_part" /mnt/boot
info "Installing base system (pacstrap)..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware \
    networkmanager sudo openssh ufw vim man-db man-pages texinfo \
    systemd efibootmgr cryptsetup

genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------------------------------------------------------
# 7. Chroot configuration
# -----------------------------------------------------------------------------
info "Entering chroot to configure system..."

# Helper pour exécuter des commandes simples
chroot_cmd() {
    arch-chroot /mnt /bin/bash -c "$1"
}

chroot_cmd "ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime"
chroot_cmd "hwclock --systohc"

chroot_cmd "sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen"
chroot_cmd "locale-gen"
chroot_cmd "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"

chroot_cmd "echo 'KEYMAP=fr' > /etc/vconsole.conf"

default_hostname="archlinux"
read -rp "Enter hostname (default: $default_hostname): " hostname
hostname=${hostname:-$default_hostname}
chroot_cmd "echo '$hostname' > /etc/hostname"
chroot_cmd "echo '127.0.0.1 localhost' >> /etc/hosts"
chroot_cmd "echo '::1       localhost' >> /etc/hosts"
chroot_cmd "echo '127.0.1.1 $hostname.localdomain $hostname' >> /etc/hosts"

warn "Setting root password."
while true; do
    read -rsp "New root password (default 'root' is insecure): " root_pass
    echo
    read -rsp "Confirm root password: " root_pass2
    echo
    if [[ "$root_pass" == "$root_pass2" && -n "$root_pass" ]]; then
        # Éviter l'injection via printf
        printf "%s\n" "root:$root_pass" | arch-chroot /mnt chpasswd
        break
    else
        error "Passwords do not match or empty."
    fi
done

chroot_cmd "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/10-wheel"
chroot_cmd "chmod 440 /etc/sudoers.d/10-wheel"

if ask_yes_no "Create a regular user with sudo privileges?" yes; then
    read -rp "Username: " username
    while [[ -z "$username" ]]; do
        read -rp "Username cannot be empty: " username
    done
    chroot_cmd "useradd -m -G wheel -s /bin/bash $username"
    while true; do
        read -rsp "Password for $username: " user_pass
        echo
        read -rsp "Confirm password: " user_pass2
        echo
        if [[ "$user_pass" == "$user_pass2" && -n "$user_pass" ]]; then
            printf "%s\n" "$username:$user_pass" | arch-chroot /mnt chpasswd
            break
        else
            error "Passwords do not match or empty."
        fi
    done
fi

chroot_cmd "systemctl enable NetworkManager"

chroot_cmd "ufw default deny incoming"
chroot_cmd "ufw default allow outgoing"
chroot_cmd "ufw allow ssh"
chroot_cmd "ufw --force enable"
chroot_cmd "systemctl enable ufw"

# sed avec # facultatif
chroot_cmd "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
chroot_cmd "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
chroot_cmd "sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config"
chroot_cmd "systemctl enable sshd"

# -----------------------------------------------------------------------------
# 8. Mkinitcpio (encrypt hook)
# -----------------------------------------------------------------------------
if [[ "$luks" == true ]]; then
    info "Adding keyboard and encrypt hooks to mkinitcpio..."
    chroot_cmd "sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf"
else
    chroot_cmd "sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf"
fi
chroot_cmd "mkinitcpio -P"

# -----------------------------------------------------------------------------
# 9. systemd-boot installation
# -----------------------------------------------------------------------------
info "Installing systemd-boot..."
chroot_cmd "bootctl --path=/boot install"

cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 4
console-mode max
EOF

# Kernel parameters : cryptdevice pour le hook encrypt
root_cmd="root=$root_mapper rw"
if [[ "$luks" == true ]]; then
    luks_uuid=$(blkid -s UUID -o value "$root_part")
    root_cmd="cryptdevice=UUID=$luks_uuid:cryptroot root=/dev/mapper/cryptroot rw"
fi

cat > /mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options $root_cmd
EOF

cp /mnt/boot/loader/entries/arch.conf /mnt/boot/loader/entries/arch-fallback.conf
sed -i 's/initramfs-linux.img/initramfs-linux-fallback.img/' /mnt/boot/loader/entries/arch-fallback.conf

# -----------------------------------------------------------------------------
# 10. Final cleanup
# -----------------------------------------------------------------------------
success "Installation completed successfully!"
echo -e "${GREEN}==================================================${NC}"
echo "You can now reboot. Before rebooting:"
echo "  - If you set up LUKS, remember your passphrase."
echo "  - For SSH key‑only authentication, place your public key in"
echo "    /home/<user>/.ssh/authorized_keys (if you created a user)."
echo "  - Root login via SSH is disabled; password authentication is off."
echo
echo "Log of this installation is saved at: $LOG_FILE"
echo
read -rp "Press Enter to unmount and exit (you can then 'reboot')."

umount -R /mnt
if [[ "$luks" == true ]]; then
    cryptsetup close cryptroot
fi

success "Done. Goodbye!"
