#!/bin/bash

# Arch Linux Automated Installation Script
# Based on your usual installation process

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Configuration variables
DISK="/dev/sda"
VG_NAME="gandalf"
ROOT_SIZE="20G"
HOSTNAME="sarchura"
USERNAME="screamnox"
TIMEZONE="Europe/Paris"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Check if we're in UEFI mode
if [[ ! -d /sys/firmware/efi ]]; then
    error "This script requires UEFI boot mode"
fi

log "Starting Arch Linux automated installation..."

# Initial setup
log "Setting up keyboard and font..."
loadkeys fr
setfont ter-132b

# Check UEFI firmware platform
if [[ $(cat /sys/firmware/efi/fw_platform_size 2>/dev/null) != "64" ]]; then
    warn "Not running on 64-bit UEFI"
fi

# Check internet connectivity
log "Checking internet connectivity..."
if ! ping -c 3 archlinux.org > /dev/null 2>&1; then
    error "No internet connection. Please check your network."
fi

# Time synchronization
log "Synchronizing time..."
timedatectl

# Display current disk layout
log "Current disk layout:"
fdisk -l

# Confirm disk selection
echo -e "${YELLOW}WARNING: This will completely wipe ${DISK}!${NC}"
while true; do
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r confirm
    confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    if [[ $confirm == "yes" || $confirm == "y" ]]; then
        break
    elif [[ $confirm == "no" || $confirm == "n" ]]; then
        error "Installation cancelled by user"
    else
        echo "Please enter 'yes' or 'no'"
    fi
done

# Partition the disk
log "Partitioning disk ${DISK}..."
# Create GPT partition table and partitions
fdisk ${DISK} << EOF
g
n


+1G
t
1
n



t
2
44
p
w
EOF

# Wait for partitions to be recognized
sleep 2
partprobe ${DISK}

log "Partition layout created:"
lsblk ${DISK}

# LVM on LUKS setup
log "Setting up LUKS encryption..."
echo "You will need to enter a passphrase for disk encryption:"
cryptsetup luksFormat ${DISK}2

echo "Enter the passphrase again to open the encrypted partition:"
cryptsetup open ${DISK}2 cryptlvm

log "Setting up LVM..."
pvcreate /dev/mapper/cryptlvm
vgcreate ${VG_NAME} /dev/mapper/cryptlvm

log "Current VG status:"
vgdisplay

log "Creating logical volumes..."
lvcreate -L ${ROOT_SIZE} -n root ${VG_NAME}
lvcreate -l +100%FREE -n home ${VG_NAME}
lvreduce -L -256M ${VG_NAME}/home --yes

log "Logical volumes created:"
lvdisplay

# Format partitions
log "Formatting partitions..."
mkfs.ext4 /dev/${VG_NAME}/root
mkfs.ext4 /dev/${VG_NAME}/home
mkfs.fat -F 32 ${DISK}1

# Mount partitions
log "Mounting partitions..."
mount /dev/${VG_NAME}/root /mnt
mount --mkdir /dev/${VG_NAME}/home /mnt/home
mount --mkdir ${DISK}1 /mnt/boot

log "Mount points:"
lsblk

# Install essential packages
log "Installing essential packages..."
pacstrap -K /mnt base linux linux-firmware

# Generate fstab
log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Create chroot script
log "Creating chroot configuration script..."
cat << 'CHROOT_SCRIPT' > /mnt/arch_chroot.sh
#!/bin/bash

set -euo pipefail

# Colors
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[CHROOT] $1${NC}"
}

log "Configuring system inside chroot..."

# Set timezone
log "Setting timezone..."
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
date

# Install additional packages
log "Installing additional packages..."
pacman -Syu --noconfirm vim sudo lvm2 man-pages man-db texinfo openssh git networkmanager

# Configure locale
log "Configuring locale..."
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf

# Set hostname
log "Setting hostname..."
echo "sarchura" > /etc/hostname

# Enable NetworkManager
log "Enabling NetworkManager..."
systemctl enable NetworkManager

# Configure mkinitcpio
log "Configuring mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install and configure systemd-boot
log "Installing systemd-boot..."
bootctl install
bootctl update

# Get UUID of encrypted partition
DEVICE_UUID=$(blkid -o value -s UUID /dev/sda2)

# Create boot entry
log "Creating boot entry..."
cat > /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rd.luks.name=${DEVICE_UUID}=cryptlvm root=/dev/gandalf/root rw
EOF

# Rebuild initramfs
mkinitcpio -P

# Create user
log "Creating user..."
useradd -m -G wheel screamnox

# Set root password
log "Setting root password..."
echo "Please set the root password:"
passwd

# Set user password
log "Setting user password..."
echo "Please set the password for user screamnox:"
passwd screamnox

# Configure sudo
log "Configuring sudo..."
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

log "Chroot configuration completed!"
CHROOT_SCRIPT

# Make the chroot script executable
chmod +x /mnt/arch_chroot.sh

# Execute chroot script
log "Entering chroot environment..."
arch-chroot /mnt /arch_chroot.sh

# Clean up
log "Cleaning up..."
rm /mnt/arch_chroot.sh

# Unmount and reboot
log "Installation completed! Unmounting filesystems..."
umount -R /mnt

echo -e "${GREEN}"
echo "================================================"
echo "  Arch Linux installation completed successfully!"
echo "================================================"
echo -e "${NC}"
echo "The system will reboot in 10 seconds..."
echo "Press Ctrl+C to cancel the reboot."

sleep 10
reboot
