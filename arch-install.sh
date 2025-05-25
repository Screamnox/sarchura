#!/usr/bin/env bash
# Automated Arch Linux installer for UEFI + LUKS + LVM setup
# Tested with Arch ISO (2025)
set -euo pipefail
shopt -s inherit_errexit

########## Configuration ##########
# Block device to install on (e.g., /dev/sda)
DISK="/dev/sda"
# LUKS passphrase (will prompt if empty)
LUKS_PASSWORD=""
# Hostname
HOSTNAME="archbox"
# Username and passwords
USERNAME="user"
ROOT_PASSWORD=""
USER_PASSWORD=""
# Locale & timezone
KEYMAP="fr"
FONT="ter-132b"
TIMEZONE="Europe/Paris"
LOCALE="en_US.UTF-8"

########## Functions ##########
confirm_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

prompt_pw() {
  local var_name="$1"
  local prompt_msg="$2"
  local pw
  local pw2
  
  while [ -z "${!var_name}" ]; do
    read -rsp "$prompt_msg: " pw
    echo
    read -rsp "Confirm $prompt_msg: " pw2
    echo
    if [ "$pw" = "$pw2" ]; then
      eval "$var_name=\"$pw\""
    else
      echo "Passwords do not match, try again."
    fi
  done
}

check_internet() {
  echo "==> Checking internet connectivity..."
  if ! ping -c3 archlinux.org >/dev/null 2>&1; then
    echo "No internet connection. Please configure network manually." >&2
    echo "For WiFi, use: iwctl device list && iwctl station wlan0 connect SSID"
    exit 1
  fi
  echo "Network OK"
}

########## Start ##########
confirm_root

echo "=== Arch Linux UEFI + LUKS + LVM Installer ==="
echo "This will COMPLETELY WIPE $DISK"
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Installation cancelled."
  exit 1
fi

# 1. Init
echo "==> Setting up console"
loadkeys "$KEYMAP"
setfont "$FONT" 2>/dev/null || echo "Font $FONT not available, using default"

# Check UEFI
if [ ! -d "/sys/firmware/efi" ]; then
  echo "System is not booted in UEFI mode." >&2
  exit 1
fi
echo "==> System in UEFI mode"

# 2. Network check
check_internet

# 3. Time sync
echo "==> Enabling NTP"
timedatectl set-ntp true

# 4. Get passwords upfront
if [ -z "$LUKS_PASSWORD" ]; then
  prompt_pw LUKS_PASSWORD "Enter LUKS passphrase"
fi
if [ -z "$ROOT_PASSWORD" ]; then
  prompt_pw ROOT_PASSWORD "Set root password"
fi
if [ -z "$USER_PASSWORD" ]; then
  prompt_pw USER_PASSWORD "Set user password for $USERNAME"
fi

# 5. Partitioning
echo "==> Partitioning $DISK"
# Unmount any existing partitions
umount -R /mnt 2>/dev/null || true

# Wipe existing partition table
wipefs -af "$DISK"

parted "$DISK" --script \
  mklabel gpt \
  mkpart ESP fat32 1MiB 1GiB \
  set 1 boot on \
  mkpart primary 1GiB 100% \
  name 1 EFI \
  name 2 LVM

# Wait for kernel to recognize partitions
sleep 2
partprobe "$DISK"

EFI_PART="${DISK}1"
LVM_PART="${DISK}2"

# 6. Setup LUKS + LVM
echo "==> Setting up LUKS on $LVM_PART"
printf "%s" "$LUKS_PASSWORD" | cryptsetup luksFormat "$LVM_PART" --batch-mode -
printf "%s" "$LUKS_PASSWORD" | cryptsetup open "$LVM_PART" cryptlvm -

echo "==> Creating LVM physical volume"
pvcreate /dev/mapper/cryptlvm
vgcreate vg_arch /dev/mapper/cryptlvm

# Logical volumes: 20G for root, rest for home
lvcreate -L 20G -n root vg_arch
lvcreate -l 100%FREE -n home vg_arch

# 7. Filesystems
echo "==> Formatting partitions"
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "/dev/vg_arch/root"
mkfs.ext4 -F "/dev/vg_arch/home"

# 8. Mount
echo "==> Mounting filesystems"
mount "/dev/vg_arch/root" /mnt
mkdir -p /mnt/{boot,home}
mount "$EFI_PART" /mnt/boot
mount "/dev/vg_arch/home" /mnt/home

# 9. Install base system
echo "==> Installing base system"
pacstrap /mnt base base-devel linux linux-firmware lvm2 vim sudo networkmanager cryptsetup

# 10. Generate fstab
echo "==> Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# 11. Get LUKS UUID for mkinitcpio
LUKS_UUID=$(blkid -s UUID -o value "$LVM_PART")

# 12. Chroot setup
cat <<EOF > /mnt/root/arch_chroot.sh
#!/usr/bin/env bash
set -e

# Timezone and locales
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Uncomment locale
sed -i 's/^#\($LOCALE.*\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<EOT >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOT

# Configure mkinitcpio for LUKS
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install and configure systemd-boot
bootctl install

# Create boot entry
mkdir -p /boot/loader/entries
cat <<EOT > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
EOT

cat <<EOT > /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options cryptdevice=UUID=$LUKS_UUID:cryptlvm root=/dev/vg_arch/root rw
EOT

# Set passwords
echo "root:$ROOT_PASSWORD" | chpasswd

# Create user
useradd -m -G wheel,audio,video,optical,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable NetworkManager
systemctl enable NetworkManager

echo "==> Chroot configuration completed"
EOF

chmod +x /mnt/root/arch_chroot.sh

# 13. Enter chroot and run configuration
echo "==> Entering chroot to complete installation"
arch-chroot /mnt /root/arch_chroot.sh

# 14. Cleanup
echo "==> Cleaning up"
rm /mnt/root/arch_chroot.sh

# Unmount filesystems
echo "==> Unmounting filesystems"
umount -R /mnt
cryptsetup close cryptlvm

echo ""
echo "=== Installation Complete! ==="
echo "System will reboot in 5 seconds..."
echo "After reboot, you'll be prompted for LUKS passphrase"
echo "Login as root or $USERNAME with the passwords you set"
echo ""
sleep 5
reboot
