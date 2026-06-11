#!/usr/bin/env bash
# Arch Linux Interactive Installer (UEFI)
# Run from live ISO after booting in UEFI mode.
# Must be executed as root.

set -euo pipefail

# ---- Colors ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---- Helper Functions ----
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
ask()   { echo -e "${CYAN}[?]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    ask "$prompt (y/N): "
    read -r answer
    [[ "$answer" =~ ^[yY]$ ]]
}

# select_from_list: prints menu to stderr, returns chosen string to stdout.
# Usage: choice=$(select_from_list "Title" "${options[@]}")
select_from_list() {
    local title="$1"; shift
    local options=("$@")
    if [[ ${#options[@]} -eq 0 ]]; then
        error "No options available."
    fi
    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
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
