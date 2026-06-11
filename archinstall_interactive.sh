#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  COLOUR DEFINITIONS
# ============================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

# ============================================================
#  HELPER FUNCTIONS
# ============================================================
info() {
    echo -e "${GREEN}[INFO]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
    exit 1
}

ask() {
    echo -e "${CYAN}[?]${RESET} $*"
}

confirm() {
    local answer
    ask "$1 (y/N): "
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

select_from_list() {
    local title="$1"
    shift
    local options=("$@")
    local choice

    if [[ ${#options[@]} -eq 0 ]]; then
        error "No options available for: $title"
    fi

    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}  $title${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    for i in "${!options[@]}"; do
        printf "  %2d) %s\n" $((i+1)) "${options[$i]}"
    done

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    ask "Enter number [1-${#options[@]}]: "
    read -r choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
        error "Invalid selection: $choice"
    fi

    echo "${options[$((choice-1))]}"
}

refresh_partitions() {
    partprobe || true
    udevadm settle --timeout=10 || true
    sleep 1
}

get_part_type_guid() {
    local part="$1"
    lsblk -n -o PARTTYPE "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

# ============================================================
#  PREREQUISITE CHECKS
# ============================================================
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo or live ISO root)."
fi

if [[ ! -d /sys/firmware/efi ]]; then
    error "Not booted in UEFI mode. Please reboot in UEFI mode."
fi

if ! command -v pacstrap &>/dev/null; then
    error "This script must be run from the Arch Linux live ISO."
fi

# ============================================================
#  STEP 1: DISK SELECTION
# ============================================================
info "Scanning available disks..."
mapfile -t disk_list < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v loop)

if [[ ${#disk_list[@]} -eq 0 ]]; then
    error "No disks found."
fi

declare -a disk_display=()
declare -A disk_device=()
for entry in "${disk_list[@]}"; do
    read -r name size model <<< "$entry"
    disk_display+=("/dev/$name | $size | $model")
    disk_device["/dev/$name | $size | $model"]="/dev/$name"
done

selected_disk_desc=$(select_from_list "Available disks" "${disk_display[@]}")
SELECTED_DISK="${disk_device[$selected_disk_desc]}"
info "Selected disk: $SELECTED_DISK"

# ============================================================
#  STEP 2: INSTALLATION MODE
# ============================================================
mode_choices=(
    "Install on whole disk (will partition automatically)"
    "Use an existing partition as root (will be FORMATTED)"
)
selected_mode=$(select_from_list "Installation mode" "${mode_choices[@]}")

if [[ "$selected_mode" == "${mode_choices[0]}" ]]; then
    WHOLE_DISK=true
    USE_EXISTING_ROOT=false
else
    WHOLE_DISK=false
    USE_EXISTING_ROOT=true
fi

# ============================================================
#  STEP 3: FULL DISK WIPE (only if WHOLE_DISK)
# ============================================================
WIPE_DISK=false
if $WHOLE_DISK && confirm "Do you want to wipe the entire disk and create a fresh GPT label?"; then
    ask "Type YES to confirm: "
    read -r confirm_wipe
    if [[ "$confirm_wipe" != "YES" ]]; then
        warn "Wipe not confirmed – skipping wipe."
    else
        WIPE_DISK=true
        info "Will wipe the disk and create a new partition table."
    fi
fi

# ============================================================
#  STEP 4: ROOT PARTITION SELECTION (if using existing)
# ============================================================
ROOT_PART=""
if $USE_EXISTING_ROOT; then
    info "Scanning partitions (size >= 8 GiB)..."
    mapfile -t all_parts < <(lsblk -n -o NAME,SIZE,FSTYPE,LABEL,TYPE | grep part)

    declare -a valid_parts=()
    declare -A part_info=()
    for part in "${all_parts[@]}"; do
        read -r name raw_size fstype label type <<< "$part"
        # Convert size to bytes and check >= 8 GiB
        size_bytes=$(numfmt --from=iec "$raw_size" 2>/dev/null || echo 0)
        if [[ $size_bytes -ge $((8*1024*1024*1024)) ]]; then
            size_gib=$(numfmt --to=iec "$size_bytes" 2>/dev/null)
            entry="/dev/$name | ${size_gib}B | ${fstype:-none} | ${label:-none}"
            valid_parts+=("$entry")
            part_info["$entry"]="/dev/$name"
        fi
    done

    if [[ ${#valid_parts[@]} -eq 0 ]]; then
        error "No suitable root partition found (>=8 GiB)."
    fi

    selected_part_desc=$(select_from_list "Available partitions for root (will be FORMATTED)" "${valid_parts[@]}")
    ROOT_PART="${part_info[$selected_part_desc]}"
    if ! confirm "ALL DATA on $ROOT_PART will be LOST. Continue?"; then
        error "User aborted."
    fi
fi

# ============================================================
#  STEP 5: EFI SYSTEM PARTITION HANDLING
# ============================================================
EFI_PART=""
CREATE_EFI=false

find_existing_efi() {
    mapfile -t parts < <(lsblk -n -o NAME,SIZE,PARTTYPE | grep -v loop)
    declare -a efi_parts=()
    for p in "${parts[@]}"; do
        read -r name size parttype <<< "$p"
        parttype_lower=$(echo "$parttype" | tr '[:upper:]' '[:lower:]')
        if [[ "$parttype_lower" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
            efi_parts+=("/dev/$name | ${size}B")
        fi
    done
    echo "${efi_parts[@]}"
}

efi_options=()
if $WHOLE_DISK && $WIPE_DISK; then
    # EFI will be created as partition 1 later
    CREATE_EFI=true
else
    existing_efi=($(find_existing_efi))
    if [[ ${#existing_efi[@]} -gt 0 ]]; then
        efi_options=("${existing_efi[@]}")
        efi_options+=("Create a new EFI partition (on $SELECTED_DISK)")
        efi_options+=("No EFI partition (abort)")
        efi_choice=$(select_from_list "EFI partition handling" "${efi_options[@]}")
        if [[ "$efi_choice" == "Create a new EFI partition (on $SELECTED_DISK)" ]]; then
            CREATE_EFI=true
        elif [[ "$efi_choice" == "No EFI partition (abort)" ]]; then
            error "EFI partition is required for UEFI boot. Aborting."
        else
            # An existing partition was chosen
            EFI_PART=$(echo "$efi_choice" | cut -d'|' -f1 | xargs)
            CREATE_EFI=false
        fi
    else
        if confirm "No EFI partition found. Create a new 1 GiB EFI partition on $SELECTED_DISK?"; then
            CREATE_EFI=true
        else
            error "EFI partition required – aborting."
        fi
    fi
fi

# Create EFI partition if needed
if $CREATE_EFI; then
    if $WHOLE_DISK && $WIPE_DISK; then
        info "Creating fresh GPT and EFI partition (partition 1) on $SELECTED_DISK..."
        parted -s "$SELECTED_DISK" mklabel gpt
        parted -s "$SELECTED_DISK" mkpart primary fat32 1MiB 1025MiB
        parted -s "$SELECTED_DISK" set 1 esp on
        refresh_partitions
        EFI_PART="${SELECTED_DISK}1"
        # Wait for partition to appear
        while [[ ! -b "$EFI_PART" ]]; do sleep 0.5; done
    else
        info "Creating EFI partition in free space on $SELECTED_DISK..."
        # Find free space start in bytes
        free_info=$(parted -s "$SELECTED_DISK" unit B print free | grep "Free Space" | tail -1)
        start=$(echo "$free_info" | awk '{print $1}' | tr -d 'B')
        if [[ -z "$start" ]]; then
            error "No free space found on $SELECTED_DISK to create EFI partition."
        fi
        end=$((start + 1024*1024*1024 - 1))  # 1 GiB
        parted -s "$SELECTED_DISK" mkpart primary fat32 "${start}B" "${end}B"
        parted -s "$SELECTED_DISK" set 1 esp on
        refresh_partitions
        # Determine the new partition device
        EFI_PART=$(lsblk -n -o NAME "$SELECTED_DISK" | tail -1)
        EFI_PART="/dev/$EFI_PART"
        while [[ ! -b "$EFI_PART" ]]; do sleep 0.5; done
    fi
    info "Formatting EFI partition as FAT32..."
    mkfs.fat -F32 "$EFI_PART"
fi

if [[ -z "$EFI_PART" ]] && ! $CREATE_EFI; then
    error "EFI partition not set properly."
fi

# ============================================================
#  STEP 6: ROOT PARTITION CREATION (if not using existing)
# ============================================================
CREATE_ROOT_PART=false
if ! $USE_EXISTING_ROOT; then
    CREATE_ROOT_PART=true
fi

if $CREATE_ROOT_PART; then
    info "Finding largest free space on $SELECTED_DISK..."
    # Get free space in bytes
    free_lines=$(parted -s "$SELECTED_DISK" unit B print free | grep "Free Space")
    if [[ -z "$free_lines" ]]; then
        error "No free space found on $SELECTED_DISK."
    fi
    # Choose largest free segment
    largest_start=0
    largest_size=0
    while read -r line; do
        start=$(echo "$line" | awk '{print $1}' | tr -d 'B')
        end=$(echo "$line" | awk '{print $3}' | tr -d 'B')
        size=$((end - start))
        if [[ $size -gt $largest_size ]]; then
            largest_size=$size
            largest_start=$start
        fi
    done <<< "$free_lines"

    if [[ $largest_size -lt $((8*1024*1024*1024)) ]]; then
        error "Not enough free space (<8 GiB) for root partition."
    fi

    largest_gib=$((largest_size / 1024 / 1024 / 1024))
    ask "Root partition size in GiB (min 8, max $largest_gib, default=$largest_gib): "
    read -r root_size
    if [[ -z "$root_size" ]]; then
        root_size=$largest_gib
    fi
    if ! [[ "$root_size" =~ ^[0-9]+$ ]] || [[ $root_size -lt 8 ]] || [[ $root_size -gt $largest_gib ]]; then
        error "Invalid size. Must be integer between 8 and $largest_gib."
    fi

    root_size_bytes=$((root_size * 1024 * 1024 * 1024))
    root_end=$((largest_start + root_size_bytes - 1))
    info "Creating root partition from ${largest_start}B to ${root_end}B..."
    parted -s "$SELECTED_DISK" mkpart primary "${largest_start}B" "${root_end}B"
    refresh_partitions
    # New partition is the last one on the disk
    ROOT_PART=$(lsblk -n -o NAME "$SELECTED_DISK" | grep -E '^[a-z]+[0-9]+$' | tail -1)
    ROOT_PART="/dev/$ROOT_PART"
    while [[ ! -b "$ROOT_PART" ]]; do sleep 0.5; done
    info "Root partition created: $ROOT_PART"
fi

# ============================================================
#  STEP 7: FILESYSTEM & ENCRYPTION
# ============================================================
fs_choices=("ext4" "btrfs" "xfs")
root_fs=$(select_from_list "Root filesystem type" "${fs_choices[@]}")

ENCRYPT=false
if confirm "Encrypt root partition with LUKS?"; then
    ENCRYPT=true
fi

if $ENCRYPT; then
    info "Setting up LUKS encryption on $ROOT_PART..."
    cryptsetup luksFormat --type luks2 "$ROOT_PART" --force-password || error "LUKS format failed"
    cryptsetup open "$ROOT_PART" cryptroot
    ROOT_MAPPER="/dev/mapper/cryptroot"
else
    ROOT_MAPPER="$ROOT_PART"
fi

info "Formatting $ROOT_MAPPER as $root_fs..."
case "$root_fs" in
    ext4) mkfs.ext4 -F "$ROOT_MAPPER" ;;
    btrfs) mkfs.btrfs -f "$ROOT_MAPPER" ;;
    xfs) mkfs.xfs -f "$ROOT_MAPPER" ;;
esac

# ============================================================
#  STEP 8: MOUNTING
# ============================================================
info "Mounting root to /mnt..."
mount "$ROOT_MAPPER" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ============================================================
#  STEP 9: BASE SYSTEM INSTALLATION
# ============================================================
info "Installing base system (this may take a while)..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware networkmanager sudo openssh ufw vim man-db man-pages texinfo nano reflector || error "pacstrap failed"

info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
#  STEP 10: CHROOT CONFIGURATION
# ============================================================
info "Configuring system inside chroot..."

cat > /mnt/configure.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Keyboard layout (French)
echo "KEYMAP=fr" > /etc/vconsole.conf

# Timezone & clock
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
read -p "Enter hostname [archlinux]: " hostname
hostname=${hostname:-archlinux}
echo "$hostname" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain $hostname
HOSTS

# Root password
if [[ "$(confirm_set_password)" == "yes" ]]; then
    echo "Set root password:"
    passwd
else
    warn "Root password not set – insecure!"
fi

# Sudo user creation
if [[ "$(confirm_create_user)" == "yes" ]]; then
    while true; do
        read -p "Username: " username
        if [[ -n "$username" ]]; then break; fi
    done
    useradd -m -G wheel -s /bin/bash "$username"
    passwd "$username"
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

# Enable services
systemctl enable NetworkManager

# UFW setup
if [[ "$(confirm_enable_ufw)" == "yes" ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw --force enable
    systemctl enable ufw
fi

# SSH setup
if [[ "$(confirm_enable_ssh)" == "yes" ]]; then
    systemctl enable sshd
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
fi

# Parallel downloads & multilib
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
pacman -Sy --noconfirm

# Reflector
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# systemd-boot
bootctl install

# Prepare boot entry
root_uuid=$(blkid -s UUID -o value "$ROOT_MAPPER_ORIG")
root_partuuid=$(blkid -s PARTUUID -o value "$ROOT_PART_ORIG")

cat > /boot/loader/entries/arch.conf << BOOTENTRY
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options BOOT_OPTIONS
BOOTENTRY

# Replace BOOT_OPTIONS placeholder
if [[ "$ENCRYPT" == "true" ]]; then
    sed -i "s|BOOT_OPTIONS|cryptdevice=UUID=$root_uuid:cryptroot root=/dev/mapper/cryptroot rw|" /boot/loader/entries/arch.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
else
    sed -i "s|BOOT_OPTIONS|root=PARTUUID=$root_partuuid rw|" /boot/loader/entries/arch.conf
fi
mkinitcpio -p linux

cat > /boot/loader/loader.conf << LOADER
default arch.conf
timeout 4
console-mode max
LOADER

echo "Configuration finished inside chroot."
EOF

# Pass variables to chroot script
chmod +x /mnt/configure.sh
# We need to inject the values into the script or pass via environment.
# Simpler: replace placeholders directly in the generated script.
ROOT_MAPPER_ORIG="$ROOT_MAPPER"
ROOT_PART_ORIG="$ROOT_PART"
ENCRYPT_ORIG="$ENCRYPT"
sed -i "s|ROOT_MAPPER_ORIG|$ROOT_MAPPER|g; s|ROOT_PART_ORIG|$ROOT_PART|g; s|ENCRYPT=.*|ENCRYPT=$ENCRYPT|g" /mnt/configure.sh
# Replace confirm functions with simple helpers
cat >> /mnt/configure.sh << 'FUNCS'
confirm_set_password() { read -p "Set root password? (y/N): " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] && echo "yes" || echo "no"; }
confirm_create_user() { read -p "Create a sudo user? (y/N): " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] && echo "yes" || echo "no"; }
confirm_enable_ufw() { read -p "Enable UFW firewall? (y/N): " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] && echo "yes" || echo "no"; }
confirm_enable_ssh() { read -p "Enable SSH server (key only)? (y/N): " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] && echo "yes" || echo "no"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
FUNCS

arch-chroot /mnt /bin/bash /configure.sh

# Cleanup chroot script
rm /mnt/configure.sh

# ============================================================
#  STEP 11: CLEANUP & FINISH
# ============================================================
info "Unmounting..."
umount -R /mnt

if $ENCRYPT; then
    cryptsetup close cryptroot
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}                INSTALLATION COMPLETE${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
info "You may now reboot into your new Arch Linux system."

if confirm "Reset keyboard layout from French (fr) to US (us) for the live environment?"; then
    loadkeys us
    info "Keyboard layout set to US."
fi

info "Done. Run 'reboot' to restart."
