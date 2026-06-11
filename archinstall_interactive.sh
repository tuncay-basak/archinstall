#!/bin/bash

# -----------------------------------------------------------------------------
# Arch Linux Automated Installer (with systemd-boot, LUKS, French keymap)
# -----------------------------------------------------------------------------

set -euo pipefail

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="/tmp/arch_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Helper functions
error() {
    echo -e "${RED}ERROR: $*${NC}" >&2
}

warn() {
    echo -e "${YELLOW}WARNING: $*${NC}"
}

info() {
    echo -e "${CYAN}INFO: $*${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $*${NC}"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-}"
    local answer
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
    local prompt="$1"
    local answer
    read -rp "$prompt (type 'yes' to confirm): " answer
    [[ "$answer" == "yes" ]]
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
# 2. Check for existing EFI partition on p1
# -----------------------------------------------------------------------------
has_efi_on_p1() {
    local disk="$1"
    # Check if partition 1 exists and has EFI System type code (ef00 for gpt, or 'EFI System' label)
    if [[ -b "${disk}1" ]]; then
        local part_type
        part_type=$(blkid -o value -s PARTTYPE "${disk}1" 2>/dev/null || echo "")
        if [[ "$part_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
            return 0
        fi
    fi
    return 1
}

if has_efi_on_p1 "$disk"; then
    info "EFI System Partition found on ${disk}1."
    efi_exists=true
else
    efi_exists=false
    warn "No EFI System Partition found on ${disk}1."
    echo "UEFI firmware requires an EFI partition (FAT32, type EF00) to boot."
    echo "The only safe option is to wipe the disk and create a proper GPT layout."
    if confirm "Wipe entire disk $disk and create a new partition table?"; then
        info "Wiping disk $disk..."
        wipefs -a "$disk"
        parted -s "$disk" mklabel gpt
        success "Disk wiped and GPT label created."
    else
        error "Cannot proceed without a valid EFI partition. Exiting."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# 3. EFI partition creation (if wiped or not present)
# -----------------------------------------------------------------------------
if [[ "$efi_exists" == false ]]; then
    # Disk was just wiped, ask for EFI size
    default_efi_size="1GiB"
    while true; do
        read -rp "EFI partition size (default $default_efi_size, minimum 128MiB): " efi_size
        efi_size=${efi_size:-$default_efi_size}
        # Convert to bytes for comparison (simple numeric check for M/G)
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
    # Wait for partition to appear
    partprobe "$disk"
    sleep 2
    efi_part="${disk}1"
    success "EFI partition created: $efi_part"
fi

# -----------------------------------------------------------------------------
# 4. Root partition selection / creation
# -----------------------------------------------------------------------------
# If EFI didn't exist and we wiped, we already have only the EFI partition.
# Remaining space will be used for root.
if [[ "$efi_exists" == false ]]; then
    info "Creating root partition in remaining space..."
    parted -s "$disk" mkpart primary "$efi_size" 100%
    partprobe "$disk"
    sleep 2
    root_part="${disk}2"
    success "Root partition created: $root_part"
else
    # EFI partition exists on p1. Present choices for root.
    echo -e "${BLUE}Root partition selection:${NC}"
    # Gather existing partitions (excluding p1)
    existing_parts=()
    for part in $(lsblk -ln -o NAME "$disk" | grep -E "^${disk##*/}[0-9]+$" | grep -v "1$"); do
        part_path="/dev/$part"
        # Check if partition is not mounted and at least 8GiB
        if ! mount | grep -q "$part_path"; then
            size_bytes=$(blockdev --getsize64 "$part_path" 2>/dev/null || echo 0)
            if [[ $size_bytes -ge $((8*1024*1024*1024)) ]]; then
                existing_parts+=("$part_path")
            fi
        fi
    done
    # Check free unallocated space
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
                # Ask for partition size
                default_size="all"
                read -rp "Size for new partition (default $default_size, e.g. 20G, +8G): " part_size
                part_size=${part_size:-$default_size}
                # Find start of free space (first free block after p1)
                start=$(parted -s "$disk" unit MiB print free | awk '/Free Space/ {print $1}' | head -1)
                if [[ "$part_size" == "all" ]]; then
                    parted -s "$disk" mkpart primary "$start" 100%
                else
                    parted -s "$disk" mkpart primary "$start" "$part_size"
                fi
                partprobe "$disk"
                sleep 2
                # The new partition will be the last one; find it
                new_part=$(lsblk -ln -o NAME "$disk" | grep -E "^${disk##*/}[0-9]+$" | tail -1)
                root_part="/dev/$new_part"
                success "New root partition created: $root_part"
                break
                ;;
            "Use existing partition"*)
                # Extract partition path from string
                root_part=$(echo "$opt" | awk '{print $4}')
                # Double-check size
                size_bytes=$(blockdev --getsize64 "$root_part" 2>/dev/null || echo 0)
                if [[ $size_bytes -lt $((8*1024*1024*1024)) ]]; then
                    error "Partition $root_part is smaller than 8GiB. Please choose another."
                    continue
                fi
                if mount | grep -q "$root_part"; then
                    error "Partition $root_part is currently mounted. Cannot use."
                    continue
                fi
                success "Using existing partition $root_part as root."
                break
                ;;
            "Wipe entire disk and start fresh (strong confirm required)")
                echo -e "${RED}WARNING: This will erase all data on $disk, including the existing EFI partition.${NC}"
                echo "Total disk capacity: $(lsblk -dn -o SIZE "$disk")"
                total_bytes=$(blockdev --getsize64 "$disk")
                if [[ $total_bytes -lt $((9*1024*1024*1024)) ]]; then
                    error "Disk is smaller than 9GiB. Cannot continue (need at least 8GiB for root + EFI)."
                    exit 1
                fi
                if confirm "Type 'yes' to PERMANENTLY WIPE $disk"; then
                    info "Wiping disk..."
                    wipefs -a "$disk"
                    parted -s "$disk" mklabel gpt
                    # Ask EFI size again
                    default_efi_size="1GiB"
                    while true; do
                        read -rp "EFI partition size (default $default_efi_size, min 128MiB): " efi_size
                        efi_size=${efi_size:-$default_efi_size}
                        if [[ "$efi_size" =~ ^[0-9]+MiB$ ]]; then
                            size_mib=${efi_size%MiB}
                            if [[ $size_mib -ge 128 ]]; then
                                break
                            else
                                error "EFI size must be at least 128MiB."
                            fi
                        elif [[ "$efi_size" =~ ^[0-9]+GiB$ ]]; then
                            break
                        else
                            error "Invalid format."
                        fi
                    done
                    parted -s "$disk" mkpart primary fat32 1MiB "$efi_size"
                    parted -s "$disk" set 1 esp on
                    parted -s "$disk" mkpart primary "$efi_size" 100%
                    partprobe "$disk"
                    sleep 2
                    efi_part="${disk}1"
                    root_part="${disk}2"
                    success "New partitions created: EFI=$efi_part, root=$root_part"
                    break
                else
                    echo "Aborted wipe. Please choose another option."
                    continue
                fi
                ;;
            *) echo "Invalid option" ;;
        esac
    done
fi

# At this point we must have efi_part and root_part defined
if [[ -z "${efi_part:-}" ]]; then
    # EFI partition might be ${disk}1 (if it existed from start)
    efi_part="${disk}1"
fi
if [[ -z "${root_part:-}" ]]; then
    error "Root partition not determined. Exiting."
    exit 1
fi

info "EFI partition: $efi_part"
info "Root partition: $root_part"

# -----------------------------------------------------------------------------
# 5. LUKS encryption
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
# 6. Filesystem format
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

# Format EFI (always FAT32)
info "Formatting EFI partition..."
mkfs.fat -F32 "$efi_part"

# Format root (with or without LUKS)
if [[ "$luks" == true ]]; then
    info "Setting up LUKS on $root_part..."
    echo -n "$luks_pass" | cryptsetup luksFormat --type luks2 "$root_part" -
    echo -n "$luks_pass" | cryptsetup open "$root_part" cryptroot -
    root_mapper="/dev/mapper/cryptroot"
    info "Formatting encrypted volume as $fs..."
    mkfs."$fs" "$root_mapper"
else
    root_mapper="$root_part"
    info "Formatting $root_part as $fs..."
    mkfs."$fs" "$root_part"
fi

# -----------------------------------------------------------------------------
# 7. Mount and pacstrap
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
# 8. Chroot configuration (step by step)
# -----------------------------------------------------------------------------
info "Entering chroot to configure system..."

# Helper to run commands inside chroot
chroot_cmd() {
    arch-chroot /mnt /bin/bash -c "$1"
}

# Set timezone
info "Setting timezone to Europe/Paris..."
chroot_cmd "ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime"
chroot_cmd "hwclock --systohc"

# Locale
info "Configuring locale (en_US.UTF-8)..."
chroot_cmd "sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen"
chroot_cmd "locale-gen"
chroot_cmd "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"

# Keyboard layout (French) – active before cryptsetup
info "Setting console keymap to fr (loadkeys fr at boot)..."
chroot_cmd "echo 'KEYMAP=fr' > /etc/vconsole.conf"

# Hostname
default_hostname="archlinux"
read -rp "Enter hostname (default: $default_hostname): " hostname
hostname=${hostname:-$default_hostname}
chroot_cmd "echo '$hostname' > /etc/hostname"
chroot_cmd "echo '127.0.0.1 localhost' >> /etc/hosts"
chroot_cmd "echo '::1       localhost' >> /etc/hosts"
chroot_cmd "echo '127.0.1.1 $hostname.localdomain $hostname' >> /etc/hosts"

# Root password
warn "Setting root password."
while true; do
    read -rsp "New root password (default 'root' is insecure): " root_pass
    echo
    read -rsp "Confirm root password: " root_pass2
    echo
    if [[ "$root_pass" == "$root_pass2" && -n "$root_pass" ]]; then
        chroot_cmd "echo 'root:$root_pass' | chpasswd"
        break
    else
        error "Passwords do not match or empty. Try again."
    fi
done

# Sudo: allow wheel group
chroot_cmd "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/10-wheel"
chroot_cmd "chmod 440 /etc/sudoers.d/10-wheel"

# Create sudo user
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
            chroot_cmd "echo '$username:$user_pass' | chpasswd"
            break
        else
            error "Passwords do not match or empty."
        fi
    done
fi

# NetworkManager
info "Enabling NetworkManager..."
chroot_cmd "systemctl enable NetworkManager"

# UFW
info "Configuring UFW..."
chroot_cmd "ufw default deny incoming"
chroot_cmd "ufw default allow outgoing"
chroot_cmd "ufw allow ssh"
chroot_cmd "ufw --force enable"
chroot_cmd "systemctl enable ufw"

# SSH (key only, no root login, no password)
info "Configuring SSH..."
chroot_cmd "sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
chroot_cmd "sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
chroot_cmd "sed -i 's/^#ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config"
chroot_cmd "systemctl enable sshd"

# -----------------------------------------------------------------------------
# 9. Mkinitcpio (with keyboard/encrypt hooks if LUKS)
# -----------------------------------------------------------------------------
if [[ "$luks" == true ]]; then
    info "Adding keyboard and encrypt hooks to mkinitcpio..."
    # Insert keyboard and keymap before encrypt, and encrypt before filesystems
    chroot_cmd "sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap encrypt filesystems fsck)/' /etc/mkinitcpio.conf"
else
    # Still include keyboard for local ttys
    chroot_cmd "sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard keymap filesystems fsck)/' /etc/mkinitcpio.conf"
fi
chroot_cmd "mkinitcpio -P"

# -----------------------------------------------------------------------------
# 10. systemd-boot installation
# -----------------------------------------------------------------------------
info "Installing systemd-boot..."
chroot_cmd "bootctl --path=/boot install"

# Create loader.conf
cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 4
console-mode max
EOF

# Prepare kernel parameters
root_cmd="root=$root_mapper rw"
if [[ "$luks" == true ]]; then
    # Get UUID of the LUKS partition
    luks_uuid=$(blkid -s UUID -o value "$root_part")
    root_cmd="rd.luks.name=$luks_uuid=cryptroot root=/dev/mapper/cryptroot rw"
fi
# Add quiet? optional
cat > /mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options $root_cmd
EOF

# If LUKS, also add fallback with same params (already in initramfs)
cp /mnt/boot/loader/entries/arch.conf /mnt/boot/loader/entries/arch-fallback.conf
sed -i 's/initramfs-linux.img/initramfs-linux-fallback.img/' /mnt/boot/loader/entries/arch-fallback.conf

# -----------------------------------------------------------------------------
# 11. Final messages and unmount
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

# Unmount
umount -R /mnt
if [[ "$luks" == true ]]; then
    cryptsetup close cryptroot
fi

success "Done. Goodbye!"    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "${BLUE}${title}${NC}" >&2
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    for i in "${!options[@]}"; do
        printf " %2d) %s\n" $((i+1)) "${options[$i]}" >&2
    done
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" >&2
    local choice_num
    while true; do
        ask "Enter selection number: "
        read -r choice_num
        if [[ "$choice_num" =~ ^[0-9]+$ ]] && (( choice_num >= 1 && choice_num <= ${#options[@]} )); then
            echo "${options[$((choice_num-1))]}"
            return 0
        else
            warn "Invalid selection. Try again."
        fi
    done
}

# ---- Preliminary Checks ----
(( EUID == 0 )) || error "This script must be run as root."
# Set keyboard layout to French (as requested)
loadkeys fr 2>/dev/null || warn "Could not set French keymap. Continuing anyway."

info "Starting Arch Linux installation..."

# ---- 1. Disk Selection ----
info "Scanning available disks..."
disk_list=()
disk_devices=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # lsblk -d -n -o NAME,SIZE,MODEL
    name=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    model=$(echo "$line" | cut -d' ' -f3-)
    # skip loop devices
    [[ "$name" =~ loop ]] && continue
    disk_list+=("/dev/$name | $size | $model")
    disk_devices+=("/dev/$name")
done < <(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null)

if [[ ${#disk_list[@]} -eq 0 ]]; then
    error "No disks found. Aborting."
fi

selected_disk=$(select_from_list "Select installation disk:" "${disk_list[@]}")
# extract device path from display string
DISK="/dev/$(echo "$selected_disk" | awk -F' | ' '{print $2}')"  # field 2 is name
info "Selected disk: $DISK"

# ---- 2. Installation Mode ----
mode_options=(
    "Install on whole disk (will partition automatically)"
    "Use an existing partition as root (will be FORMATTED)"
)
mode_choice=$(select_from_list "Choose installation mode:" "${mode_options[@]}")
if [[ "$mode_choice" == *"whole disk"* ]]; then
    WHOLE_DISK=true
    USE_EXISTING_ROOT=false
else
    WHOLE_DISK=false
    USE_EXISTING_ROOT=true
fi

# ---- 3. Optional Full Disk Wipe (only whole disk) ----
WIPE_DISK=false
if $WHOLE_DISK; then
    if confirm "Do you want to completely wipe the disk ($DISK)?"; then
        warn "WARNING: This will erase ALL data on $DISK!"
        ask "Type 'YES' (uppercase) to confirm wipe: "
        read -r confirmation
        if [[ "$confirmation" == "YES" ]]; then
            WIPE_DISK=true
        else
            error "Wipe confirmation failed. Aborting."
        fi
    fi
fi

# ---- 4. Root Partition Selection (existing root) ----
ROOT_PART=""
CREATE_ROOT_PART=false
if $USE_EXISTING_ROOT; then
    info "Scanning for existing partitions (>=8 GiB)..."
    part_options=()
    part_devices=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # lsblk -b -n -o NAME,SIZE,FSTYPE,LABEL,TYPE (bytes)
        name=$(echo "$line" | awk '{print $1}')
        size_bytes=$(echo "$line" | awk '{print $2}')
        fstype=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        type=$(echo "$line" | awk '{print $5}')
        # filter part type and >= 8 GiB (8*1024^3 = 8589934592 bytes)
        if [[ "$type" == "part" ]] && (( size_bytes >= 8589934592 )); then
            size_gib=$(echo "scale=2; $size_bytes/1073741824" | bc)
            part_options+=("/dev/$name | ${size_gib} GiB | ${fstype:-none} | ${label:-none}")
            part_devices+=("/dev/$name")
        fi
    done < <(lsblk -b -n -o NAME,SIZE,FSTYPE,LABEL,TYPE 2>/dev/null)
    if [[ ${#part_options[@]} -eq 0 ]]; then
        error "No usable root partition found (>=8 GiB, type=part)."
    fi
    root_choice=$(select_from_list "Select root partition:" "${part_options[@]}")
    ROOT_PART=$(echo "$root_choice" | awk -F' | ' '{print $1}')
    if ! confirm "ALL DATA ON $ROOT_PART WILL BE LOST. Confirm?"; then
        error "Installation aborted."
    fi
else
    CREATE_ROOT_PART=true
fi

# ---- 5. EFI System Partition Handling ----
EFI_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
BOOT_PART=""
CREATE_EFI=false

if $WIPE_DISK; then
    # GPT + EFI partition already planned (will be created now)
    info "Wiping disk and creating fresh GPT with EFI partition..."
    parted -s "$DISK" mklabel gpt
    # Create 1 GiB EFI partition at start
    parted -s "$DISK" mkpart primary fat32 1MiB 1025MiB   # 1GiB + 1MiB offset
    parted -s "$DISK" set 1 esp on
    partprobe "$DISK" 2>/dev/null || true
    sleep 1
    # Identify EFI partition (first partition)
    EFI_PART_NAME=$(lsblk -n -o NAME "$DISK" | head -1)
    BOOT_PART="/dev/$EFI_PART_NAME"
    info "Created EFI partition: $BOOT_PART"
    mkfs.fat -F32 "$BOOT_PART" || error "Failed to format EFI partition."
    CREATE_EFI=false
else
    # Search for existing EFI partitions
    info "Looking for existing EFI partitions..."
    efi_list=()
    efi_devices=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(echo "$line" | awk '{print $1}')
        parttype=$(echo "$line" | awk '{print $NF}')
        # case-insensitive GUID match
        if echo "$parttype" | grep -qi "$EFI_GUID"; then
            size=$(echo "$line" | awk '{print $2}')
            fstype=$(echo "$line" | awk '{print $3}')
            label=$(echo "$line" | awk '{print $4}')
            efi_list+=("/dev/$name | $size | ${fstype:-none} | ${label:-none}")
            efi_devices+=("/dev/$name")
        fi
    done < <(lsblk -n -o NAME,SIZE,FSTYPE,LABEL,PARTTYPE 2>/dev/null)

    if [[ ${#efi_list[@]} -gt 0 ]]; then
        efi_list+=("Create a new EFI partition (on $DISK)" "No EFI partition (abort)")
        efi_choice=$(select_from_list "Select EFI partition:" "${efi_list[@]}")
        if [[ "$efi_choice" == "No EFI partition (abort)" ]]; then
            error "No EFI partition selected. Aborting."
        elif [[ "$efi_choice" == "Create a new EFI partition (on $DISK)" ]]; then
            CREATE_EFI=true
        else
            BOOT_PART=$(echo "$efi_choice" | awk -F' | ' '{print $1}')
            CREATE_EFI=false
            info "Using existing EFI partition: $BOOT_PART"
        fi
    else
        if confirm "No EFI partition found. Create a new 1 GiB EFI partition on $DISK?"; then
            CREATE_EFI=true
        else
            error "EFI partition is required for UEFI boot. Aborting."
        fi
    fi

    if $CREATE_EFI; then
        info "Creating new EFI partition on $DISK..."
        # Find free space
        free_start=""
        while IFS= read -r line; do
            [[ "$line" =~ Free\ Space ]] || continue
            # Example: "1 1048576B 1073741823B 1072693248B Free Space"
            start=$(echo "$line" | awk '{print $2}' | sed 's/B//')
            end=$(echo "$line" | awk '{print $3}' | sed 's/B//')
            size=$(( end - start ))
            if (( size >= 1073741824 )); then  # 1 GiB
                free_start="${start}B"
                break
            fi
        done < <(parted "$DISK" unit B print free 2>/dev/null)
        if [[ -z "$free_start" ]]; then
            error "No free space large enough for EFI partition (1 GiB)."
        fi
        parted -s "$DISK" mkpart primary fat32 "$free_start" "$(( ${free_start%B} + 1073741824 ))B"
        parted -s "$DISK" set "$(parted "$DISK" print | grep -c '^ [0-9]')" esp on   # last partition number
        partprobe "$DISK" 2>/dev/null || true
        sleep 1
        # get newest partition
        EFI_PART_NAME=$(lsblk -n -o NAME "$DISK" | tail -1)
        BOOT_PART="/dev/$EFI_PART_NAME"
        info "Created EFI partition: $BOOT_PART"
        mkfs.fat -F32 "$BOOT_PART" || error "Failed to format EFI partition."
        CREATE_EFI=false
    fi
fi

# ---- 6. Root Partition Creation (if needed) ----
if $CREATE_ROOT_PART; then
    info "Creating root partition on $DISK..."
    # Find largest free space
    largest_start=""
    largest_size=0
    while IFS= read -r line; do
        [[ "$line" =~ Free\ Space ]] || continue
        start=$(echo "$line" | awk '{print $2}' | sed 's/B//')
        end=$(echo "$line" | awk '{print $3}' | sed 's/B//')
        size=$(( end - start ))
        if (( size > largest_size )); then
            largest_size=$size
            largest_start="${start}B"
        fi
    done < <(parted "$DISK" unit B print free 2>/dev/null)

    if (( largest_size < 8589934592 )); then   # 8 GiB
        error "Not enough free space for root (minimum 8 GiB)."
    fi
    max_gib=$(( largest_size / 1073741824 ))
    info "Available free space: ${max_gib} GiB"
    ask "Enter root partition size in GiB (minimum 8, default $max_gib): "
    read -r root_gib
    if [[ -z "$root_gib" ]]; then
        root_gib=$max_gib
    elif ! [[ "$root_gib" =~ ^[0-9]+$ ]] || (( root_gib < 8 || root_gib > max_gib )); then
        error "Invalid size. Must be integer between 8 and $max_gib GiB."
    fi
    root_end=$(( ${largest_start%B} + root_gib * 1073741824 ))B
    parted -s "$DISK" mkpart primary ext4 "$largest_start" "$root_end"
    partprobe "$DISK" 2>/dev/null || true
    sleep 1
    ROOT_PART_NAME=$(lsblk -n -o NAME "$DISK" | tail -1)
    ROOT_PART="/dev/$ROOT_PART_NAME"
    info "Created root partition: $ROOT_PART"
fi

# ---- 7. Filesystem and Encryption ----
fs_options=("ext4" "btrfs" "xfs")
fs_choice=$(select_from_list "Choose root filesystem:" "${fs_options[@]}")

use_luks=false
if confirm "Encrypt root partition with LUKS?"; then
    use_luks=true
fi

if $use_luks; then
    info "Encrypting $ROOT_PART with LUKS..."
    cryptsetup luksFormat --type luks2 "$ROOT_PART" || error "LUKS format failed."
    cryptsetup open "$ROOT_PART" cryptroot || error "Failed to open LUKS container."
    ROOT_MAPPER="/dev/mapper/cryptroot"
else
    ROOT_MAPPER="$ROOT_PART"
fi

info "Formatting $ROOT_MAPPER with $fs_choice..."
case "$fs_choice" in
    ext4) mkfs.ext4 -F "$ROOT_MAPPER" ;;
    btrfs) mkfs.btrfs -f "$ROOT_MAPPER" ;;
    xfs) mkfs.xfs -f "$ROOT_MAPPER" ;;
    *) error "Unknown filesystem: $fs_choice" ;;
esac

# ---- 8. Mounting ----
info "Mounting root filesystem..."
mount "$ROOT_MAPPER" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# ---- 9. Base System Installation ----
info "Installing base system (pacstrap)..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware networkmanager sudo openssh ufw vim man-db man-pages texinfo nano reflector ||
    error "pacstrap failed. Check network and try again."
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ---- 10. Chroot Configuration ----
info "Configuring system inside chroot..."

chroot_cmds() {
    # Keymap, timezone, locale
    echo "KEYMAP=fr" > /etc/vconsole.conf
    ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    # Hostname
    echo -n "Enter hostname [archlinux]: "
    read hostname
    hostname=${hostname:-archlinux}
    echo "$hostname" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
EOF

    # Root password
    if confirm "Set root password? (otherwise default root with warning)"; then
        echo "Setting root password..."
        passwd
    else
        echo "Warning: root password not set. Use 'root' as default." >&2
        echo "root:root" | chpasswd
    fi

    # Sudo user
    if confirm "Create a sudo user?"; then
        while true; do
            echo -n "Enter username: "
            read username
            if [[ -n "$username" ]]; then
                useradd -m -G wheel -s /bin/bash "$username"
                passwd "$username"
                break
            else
                echo "Username cannot be empty."
            fi
        done
    fi
    # Enable wheel in sudoers
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

    # Enable NetworkManager
    systemctl enable NetworkManager

    # UFW
    if confirm "Enable and configure UFW (deny incoming, allow outgoing, allow SSH)?"; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw enable
        systemctl enable ufw
    fi

    # SSH
    if confirm "Enable SSH server and harden (no root login, no password auth)?"; then
        systemctl enable sshd
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    fi

    # systemd-boot
    bootctl install

    # Determine boot entry parameters
    root_uuid=$(blkid -s UUID -o value "${ROOT_PART}")
    root_partuuid=$(blkid -s PARTUUID -o value "${ROOT_PART}")
    if $use_luks; then
        # Add encrypt hook
        sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
        mkinitcpio -P
        options="cryptdevice=UUID=${root_uuid}:cryptroot root=/dev/mapper/cryptroot rw"
    else
        options="root=PARTUUID=${root_partuuid} rw"
    fi

    # Boot entry
    cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $options
EOF
    echo "default arch.conf" > /boot/loader/loader.conf

    # Pacman tweaks
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

    # Mirrorlist refresh
    reflector --latest 5 --sort rate --save /etc/pacman.d/mirrorlist
}

# Execute in chroot
export -f confirm info warn ask error
export ROOT_PART BOOT_PART use_luks
export -f chroot_cmds
arch-chroot /mnt /bin/bash -c chroot_cmds

# ---- 11. Cleanup ----
info "Cleaning up..."
umount -R /mnt || warn "Could not unmount cleanly."
if $use_luks; then
    cryptsetup close cryptroot
fi

info "Installation complete!"
if confirm "Reset keyboard layout from French to US?"; then
    loadkeys us 2>/dev/null
    info "Keyboard layout set to US."
fi

echo -e "${GREEN}You may now reboot into your new Arch system.${NC}"
