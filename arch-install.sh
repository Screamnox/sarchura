#!/bin/bash
set -euo pipefail
# Run as root from Arch live environment

# Variables
DISK="/dev/sda"
CRYPT_NAME="cryptlvm"
VG_NAME="gandalf"
ROOT_LV="root"
HOME_LV="home"
HOSTNAME="sarchura"
USER="icescream"
LOCALE="en_US.UTF-8"
KEYMAP="fr"
TIMEZONE="Europe/Paris"

# 1. Init
loadkeys fr
setfont ter-132b

# Check if system is UEFI 64-bit
if [[ "$(cat /sys/firmware/efi/fw_platform_size)" != "64" ]]; then
  echo "System is not 64-bit UEFI, aborting."
  exit 1
fi

ping -c 3 archlinux.org

# 2. Time check
timedatectl set-ntp true

# 3. Partition the disk
sgdisk --zap-all $DISK  # Clean partition table

# Create partitions:
# 1: EFI, 1G, type ef00 (UEFI System)
# 2: rest, type 8e00 (Linux LVM)
parted $DISK --script mklabel gpt
parted $DISK --script mkpart primary fat32 1MiB 1025MiB
parted $DISK --script set 1 boot on
parted $DISK --script name 1 EFI
parted $DISK --script mkpart primary 1025MiB 100%
parted $DISK --script name 2 LVM

# 4. Setup LUKS on /dev/sda2
echo "Set LUKS passphrase for $DISK""2"
cryptsetup luksFormat ${DISK}2
cryptsetup open ${DISK}2 $CRYPT_NAME

# 5. Setup LVM on /dev/mapper/cryptlvm
pvcreate /dev/mapper/$CRYPT_NAME
vgcreate $VG_NAME /dev/mapper/$CRYPT_NAME
lvcreate -L 20G -n $ROOT_LV $VG_NAME
lvcreate -l +100%FREE -n $HOME_LV $VG_NAME
lvreduce -L -256M $VG_NAME/$HOME_LV

# 6. Format partitions
mkfs.fat -F32 ${DISK}1
mkfs.ext4 /dev/$VG_NAME/$ROOT_LV
mkfs.ext4 /dev/$VG_NAME/$HOME_LV

# 7. Mount partitions
mount /dev/$VG_NAME/$ROOT_LV /mnt
mkdir -p /mnt/home /mnt/boot
mount /dev/$VG_NAME/$HOME_LV /mnt/home
mount ${DISK}1 /mnt/boot

# 8. Install base system
pacstrap /mnt base linux linux-firmware vim sudo lvm2 man-pages man-db texinfo openssh git networkmanager

# 9. Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 10. Configure system inside chroot
arch-chroot /mnt /bin/bash <<EOF

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Networking and packages
pacman -Syu --noconfirm networkmanager
systemctl enable NetworkManager

# mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader install and configure systemd-boot
bootctl install

UUID=$(blkid -s UUID -o value $DISK"2")
cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=$UUID=$CRYPT_NAME root=/dev/$VG_NAME/$ROOT_LV rw
EOL

cat > /boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
editor  no
EOL

# Create user and set passwords
useradd -m -G wheel $USER
echo "Set root password:"
passwd
echo "Set password for $USER:"
passwd $USER

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

EOF

# 11. Clean up and reboot
umount -R /mnt
cryptsetup close $CRYPT_NAME

echo "Installation complete. Rebooting..."
reboot
