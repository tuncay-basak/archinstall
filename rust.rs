//! Arch Linux automated installer – Rust version
//!
//! Usage:
//!   install_arch --disk /dev/nvmeXnY [--size 64GiB] [--boot /dev/efi_part] [--wipe] [--name hostname]
//!   install_arch --partition /dev/nvmeXnYpZ [--boot /dev/efi_part] [--name hostname]
//!
//! Exactly one of --disk or --partition is required.
//! --wipe only allowed with --disk.

use std::io::{self, Write};
use std::process::{Command, Stdio};
use std::str;

use anyhow::{anyhow, Context, Result};
use clap::{Arg, ArgAction, Command as ClapCommand};
use regex::Regex;

// -----------------------------------------------------------------------------
// Helper functions
// -----------------------------------------------------------------------------

/// Run an external command, capturing stdout and stderr.
/// If the command fails, returns an error with the stderr message.
fn run_cmd(cmd: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("Failed to execute '{}'", cmd))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!(
            "Command '{} {}' failed with exit code: {:?}\nStderr: {}",
            cmd,
            args.join(" "),
            output.status.code(),
            stderr
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Run a command and ignore its output – only check success.
fn run_cmd_silent(cmd: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(cmd)
        .args(args)
        .status()
        .with_context(|| format!("Failed to execute '{}'", cmd))?;

    if !status.success() {
        return Err(anyhow!("Command '{} {}' failed", cmd, args.join(" ")));
    }
    Ok(())
}

/// Interactive yes/no prompt.
fn ask_yes_no(prompt: &str, default: bool) -> Result<bool> {
    let default_str = if default { "Y/n" } else { "y/N" };
    print!("{} [{}]: ", prompt, default_str);
    io::stdout().flush()?;
    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    let input = input.trim().to_lowercase();

    if input.is_empty() {
        Ok(default)
    } else {
        Ok(input == "y" || input == "yes")
    }
}

/// Ask for a confirmation string (e.g., type "YES").
fn ask_confirm_string(prompt: &str, expected: &str) -> Result<bool> {
    print!("{} (type '{}' to confirm): ", prompt, expected);
    io::stdout().flush()?;
    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    Ok(input.trim() == expected)
}

/// Parse a size like "64GiB" into bytes.
fn parse_size(size_str: &str) -> Result<u64> {
    let re = Regex::new(r"^(\d+)GiB$").unwrap();
    let caps = re
        .captures(size_str)
        .ok_or_else(|| anyhow!("Invalid size format. Use like '64GiB'"))?;
    let num: u64 = caps[1].parse()?;
    Ok(num * 1024 * 1024 * 1024)
}

/// Get the largest free space region on a disk (start and end in bytes).
fn get_largest_free_space(disk: &str) -> Result<(u64, u64)> {
    let output = run_cmd("parted", &[disk, "unit", "B", "print", "free"])?;
    let mut free_start = 0u64;
    let mut free_end = 0u64;
    let mut largest_size = 0u64;

    for line in output.lines() {
        if line.contains("Free Space") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                let start_str = parts[0].trim_end_matches('B');
                let end_str = parts[1].trim_end_matches('B');
                let start: u64 = start_str.parse().unwrap_or(0);
                let end: u64 = end_str.parse().unwrap_or(0);
                let size = end - start;
                if size > largest_size {
                    largest_size = size;
                    free_start = start;
                    free_end = end;
                }
            }
        }
    }

    if largest_size == 0 {
        Err(anyhow!("No free space found on {}", disk))
    } else {
        Ok((free_start, free_end))
    }
}

/// Get the partition type GUID of a partition (for ESP detection).
fn get_partition_type(part: &str) -> Result<String> {
    let output = run_cmd("lsblk", &["-l", "-o", "NAME,PARTTYPE", part])?;
    for line in output.lines() {
        if line.contains(&part.trim_start_matches("/dev/")) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                return Ok(parts[1].to_string());
            }
        }
    }
    Ok(String::new())
}

/// Check if a partition is an EFI System Partition (ESP).
fn is_esp(part: &str) -> Result<bool> {
    let part_type = get_partition_type(part)?;
    // ESP GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
    Ok(part_type.to_lowercase() == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
}

/// Find all existing ESPs on the system.
fn find_existing_esp_partitions() -> Result<Vec<String>> {
    let output = run_cmd("lsblk", &["-l", "-o", "NAME"])?;
    let mut esps = Vec::new();
    for line in output.lines() {
        let name = line.trim();
        if name.is_empty() {
            continue;
        }
        let part = format!("/dev/{}", name);
        if is_esp(&part).unwrap_or(false) {
            esps.push(part);
        }
    }
    Ok(esps)
}

// -----------------------------------------------------------------------------
// Main installer logic
// -----------------------------------------------------------------------------

fn main() -> Result<()> {
    // Parse arguments using clap
    let matches = ClapCommand::new("Arch Linux Installer")
        .version("1.0")
        .author("Your Name")
        .about("Automated Arch Linux installation")
        .arg(
            Arg::new("disk")
                .long("disk")
                .value_name("/dev/nvmeXnY")
                .help("Target disk (will use free space unless --wipe)")
                .conflicts_with("partition"),
        )
        .arg(
            Arg::new("partition")
                .long("partition")
                .value_name("/dev/nvmeXnYpZ")
                .help("Existing partition to use as root (will be formatted)")
                .conflicts_with("disk"),
        )
        .arg(
            Arg::new("boot")
                .long("boot")
                .value_name("/dev/efi_partition")
                .help("EFI partition to use (optional, auto-detected if omitted)"),
        )
        .arg(
            Arg::new("size")
                .long("size")
                .value_name("64GiB")
                .help("Root partition size (only with --disk). Default: all free space."),
        )
        .arg(
            Arg::new("name")
                .long("name")
                .value_name("hostname")
                .help("Hostname (default: archlinux)")
                .default_value("archlinux"),
        )
        .arg(
            Arg::new("wipe")
                .long("wipe")
                .action(ArgAction::SetTrue)
                .help("Wipe entire disk (only with --disk)"),
        )
        .get_matches();

    // Check root privileges
    if !nix::unistd::Uid::effective().is_root() {
        eprintln!("This program must be run as root.");
        std::process::exit(1);
    }

    // Extract args
    let disk = matches.get_one::<String>("disk").cloned();
    let partition = matches.get_one::<String>("partition").cloned();
    let boot_override = matches.get_one::<String>("boot").cloned();
    let size_str = matches.get_one::<String>("size").cloned();
    let hostname = matches.get_one::<String>("name").unwrap().clone();
    let wipe_flag = matches.get_flag("wipe");

    if disk.is_none() && partition.is_none() {
        eprintln!("Error: must specify either --disk or --partition");
        std::process::exit(1);
    }

    if wipe_flag && disk.is_none() {
        eprintln!("Error: --wipe can only be used with --disk");
        std::process::exit(1);
    }

    // Set French keyboard for live session
    println!("Setting French keyboard layout (fr) for live environment");
    run_cmd_silent("loadkeys", &["fr"])?;

    // -------------------------------------------------------------------------
    // Handle --wipe case (only with --disk)
    // -------------------------------------------------------------------------
    let (mut boot_part, mut root_part) = (boot_override, None);

    if let Some(disk) = &disk {
        if wipe_flag {
            println!("WARNING: you requested --wipe. This will DESTROY ALL DATA on {}", disk);
            if !ask_confirm_string(&format!("Type 'YES' to confirm wipe of {}", disk), "YES")? {
                eprintln!("Aborted.");
                std::process::exit(0);
            }
            println!("Wiping {} and creating fresh GPT...", disk);
            run_cmd_silent("parted", &[disk, "mklabel", "gpt"])?;

            println!("Creating 1GiB EFI partition as {}p1", disk);
            run_cmd_silent("parted", &[disk, "mkpart", "primary", "fat32", "1MiB", "1025MiB"])?;
            run_cmd_silent("parted", &[disk, "set", "1", "esp", "on"])?;

            let root_size_bytes = if let Some(sz) = size_str {
                Some(parse_size(&sz)?)
            } else {
                None
            };

            if let Some(root_size) = root_size_bytes {
                let root_size_mib = root_size / 1024 / 1024;
                let root_end = 1025 + root_size_mib;
                println!("Creating root partition of exactly {} GiB (ends at {}MiB)", root_size_mib / 1024, root_end);
                run_cmd_silent("parted", &[disk, "mkpart", "primary", "ext4", "1025MiB", &format!("{}MiB", root_end)])?;
            } else {
                println!("Creating root partition using remaining space");
                run_cmd_silent("parted", &[disk, "mkpart", "primary", "ext4", "1025MiB", "100%"])?;
            }

            std::thread::sleep(std::time::Duration::from_secs(2));

            let efi_part = format!("{}p1", disk);
            let root_part_candidate = format!("{}p2", disk);
            if !std::path::Path::new(&efi_part).exists() || !std::path::Path::new(&root_part_candidate).exists() {
                eprintln!("Failed to create partitions after wipe.");
                std::process::exit(1);
            }

            println!("Formatting EFI partition (FAT32)...");
            run_cmd_silent("mkfs.fat", &["-F32", &efi_part])?;
            println!("Formatting root partition (ext4)...");
            run_cmd_silent("mkfs.ext4", &["-F", &root_part_candidate])?;

            boot_part = Some(efi_part);
            root_part = Some(root_part_candidate);
        }
    }

    // -------------------------------------------------------------------------
    // If not --wipe, handle EFI detection and root creation
    // -------------------------------------------------------------------------
    if !wipe_flag {
        // --- EFI partition determination ---
        if let Some(boot) = &boot_part {
            // User provided a boot partition
            if !std::path::Path::new(boot).exists() {
                eprintln!("Boot partition {} does not exist", boot);
                std::process::exit(1);
            }
            // Check that it's FAT32
            let fstype = run_cmd("lsblk", &["-no", "FSTYPE", boot])?;
            if !fstype.trim().eq_ignore_ascii_case("vfat") {
                eprintln!("Boot partition {} has filesystem '{}', must be FAT32", boot, fstype.trim());
                std::process::exit(1);
            }
            println!("Using user-provided EFI partition: {}", boot);
        } else {
            // Auto-detect existing ESP(s)
            let existing_esps = find_existing_esp_partitions()?;
            if !existing_esps.is_empty() {
                println!("Found existing EFI partition(s): {:?}", existing_esps);
                if ask_yes_no(&format!("Use {} as EFI partition?", existing_esps[0]), false)? {
                    boot_part = Some(existing_esps[0].clone());
                    println!("Using {}", existing_esps[0]);
                } else {
                    eprintln!("No EFI partition selected. Aborting.");
                    std::process::exit(1);
                }
            } else {
                // No ESP found. If --disk is given, create one from free space.
                if let Some(disk) = &disk {
                    println!("No existing EFI partition found. Will create a 1GiB EFI partition from free space on {}", disk);
                    let (free_start, free_end) = get_largest_free_space(disk)?;
                    let free_size = free_end - free_start;
                    if free_size < 1024 * 1024 * 1024 {
                        eprintln!("Not enough free space (need at least 1GiB, have {} bytes)", free_size);
                        std::process::exit(1);
                    }
                    let efi_end = free_start + 1024 * 1024 * 1024;
                    println!("Creating EFI partition from {}B to {}B", free_start, efi_end);
                    run_cmd_silent("parted", &[disk, "mkpart", "primary", "fat32", &format!("{}B", free_start), &format!("{}B", efi_end)])?;
                    run_cmd_silent("parted", &[disk, "set", "1", "esp", "on"])?;
                    std::thread::sleep(std::time::Duration::from_secs(2));

                    // Find the newly created partition (the last one on disk)
                    let new_part = run_cmd("lsblk", &["-l", "-o", "NAME", disk])?;
                    let lines: Vec<&str> = new_part.lines().collect();
                    if lines.len() >= 2 {
                        let last_line = lines.last().unwrap().trim();
                        let new_efi = format!("/dev/{}", last_line);
                        boot_part = Some(new_efi.clone());
                        println!("Created EFI partition: {}", new_efi);
                        run_cmd_silent("mkfs.fat", &["-F32", &new_efi])?;
                    } else {
                        eprintln!("Failed to detect newly created EFI partition");
                        std::process::exit(1);
                    }
                } else {
                    eprintln!("No EFI partition found and --disk not provided (cannot create one). Aborting.");
                    std::process::exit(1);
                }
            }
        }

        // --- Root partition creation (if --disk) ---
        if let Some(disk) = &disk {
            // We have a disk; need to create root in free space
            println!("Analyzing free space on {} for root partition...", disk);
            let (free_start, free_end) = get_largest_free_space(disk)?;
            let free_bytes = free_end - free_start;
            let free_gib = free_bytes / (1024 * 1024 * 1024);
            println!("Available free space: ~{} GiB", free_gib);

            let root_size_bytes = if let Some(sz) = size_str {
                let requested = parse_size(&sz)?;
                if requested > free_bytes {
                    eprintln!("Not enough free space. Requested {} GiB, only ~{} GiB available.", requested / (1024*1024*1024), free_gib);
                    std::process::exit(1);
                }
                requested
            } else {
                free_bytes
            };

            let root_end = free_start + root_size_bytes;
            println!("Creating root partition from {}B to {}B", free_start, root_end);
            run_cmd_silent("parted", &[disk, "mkpart", "primary", "ext4", &format!("{}B", free_start), &format!("{}B", root_end)])?;
            std::thread::sleep(std::time::Duration::from_secs(2));

            // Find the newly created partition (the last one)
            let new_part = run_cmd("lsblk", &["-l", "-o", "NAME", disk])?;
            let lines: Vec<&str> = new_part.lines().collect();
            if lines.len() >= 2 {
                let last_line = lines.last().unwrap().trim();
                let root_candidate = format!("/dev/{}", last_line);
                println!("Root partition created: {}", root_candidate);
                run_cmd_silent("mkfs.ext4", &["-F", &root_candidate])?;
                root_part = Some(root_candidate);
            } else {
                eprintln!("Failed to detect newly created root partition");
                std::process::exit(1);
            }
        } else if let Some(part) = &partition {
            // --partition case: use existing partition as root
            if !std::path::Path::new(part).exists() {
                eprintln!("Partition {} does not exist", part);
                std::process::exit(1);
            }
            // Check size >= 8 GiB
            let size_bytes = run_cmd("lsblk", &["-b", "-no", "SIZE", part])?;
            let size_gib: u64 = size_bytes.trim().parse().unwrap_or(0) / (1024 * 1024 * 1024);
            if size_gib < 8 {
                eprintln!("Partition {} is only {} GiB, need at least 8 GiB", part, size_gib);
                std::process::exit(1);
            }
            println!("Using existing partition {} ({} GiB) as root (will be formatted)", part, size_gib);
            if !ask_yes_no(&format!("Are you sure you want to format {}?", part), false)? {
                eprintln!("Aborted.");
                std::process::exit(1);
            }
            run_cmd_silent("mkfs.ext4", &["-F", part])?;
            root_part = Some(part.clone());
        }
    }

    // After all cases, we must have a boot partition and a root partition
    let boot_part = boot_part.as_ref().expect("Boot partition not determined");
    let root_part = root_part.as_ref().expect("Root partition not determined");

    // -------------------------------------------------------------------------
    // Mount and install
    // -------------------------------------------------------------------------
    println!("Mounting root partition {} to /mnt", root_part);
    run_cmd_silent("mount", &[root_part, "/mnt"])?;
    println!("Mounting EFI partition {} to /mnt/boot", boot_part);
    std::fs::create_dir_all("/mnt/boot")?;
    run_cmd_silent("mount", &[boot_part, "/mnt/boot"])?;

    println!("Installing base packages (may take a few minutes)...");
    let status = Command::new("pacstrap")
        .args(&["/mnt", "base", "base-devel", "linux", "linux-headers", "linux-firmware",
                "networkmanager", "sudo", "openssh", "ufw", "systemd", "vim", "man-db",
                "man-pages", "texinfo", "nano", "reflector"])
        .status()?;
    if !status.success() {
        eprintln!("pacstrap failed");
        std::process::exit(1);
    }

    println!("Generating fstab");
    run_cmd_silent("genfstab", &["-U", "/mnt"])?;
    // Append to /mnt/etc/fstab
    let fstab_content = run_cmd("genfstab", &["-U", "/mnt"])?;
    std::fs::write("/mnt/etc/fstab", fstab_content)?;

    // -------------------------------------------------------------------------
    // Chroot configuration (using a script to avoid shell escaping hell)
    // -------------------------------------------------------------------------
    println!("Entering chroot to configure the system");
    let chroot_script = format!(
        r#"#!/bin/bash
set -e
# French keyboard
echo "KEYMAP=fr" > /etc/vconsole.conf
# Timezone
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
# Hostname
echo "{}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   {}.localdomain {}
HOSTS
# Root password
echo "root:root" | chpasswd
# Sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
# Enable services
systemctl enable NetworkManager
systemctl enable sshd
# ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
systemctl enable ufw
# systemd-boot
bootctl install
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value {}) rw
ENTRY
echo "default arch.conf" > /boot/loader/loader.conf
# Optimizations
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
"#,
        hostname, hostname, hostname, root_part
    );

    let script_path = "/tmp/arch_chroot.sh";
    std::fs::write(script_path, chroot_script)?;
    std::fs::set_permissions(script_path, std::os::unix::fs::PermissionsExt::from_mode(0o755))?;
    run_cmd_silent("arch-chroot", &["/mnt", "/bin/bash", script_path])?;

    // -------------------------------------------------------------------------
    // Unmount and finish
    // -------------------------------------------------------------------------
    println!("Unmounting partitions");
    run_cmd_silent("umount", &["-R", "/mnt"])?;

    println!("===========================================");
    println!("Installation complete!");
    println!("You can now reboot.");
    println!("");
    println!("First login: root / root");
    println!("IMPORTANT: Change root password immediately: passwd");
    println!("");
    println!("Keyboard: fr (AZERTY)");
    println!("Firewall: ufw enabled, SSH allowed");
    println!("Bootloader: systemd-boot");
    println!("===========================================");

    Ok(())
}
