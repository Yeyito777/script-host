#!/usr/bin/env bash
set -euo pipefail

SRC_DRIVE="/dev/nvme1n1"   # Source (current Arch install)
DST_DRIVE="/dev/nvme0n1"   # Destination (new drive)
EFI_SIZE="512M"

# STEP1: Check drives exist
echo "[*] Checking drives..."
for d in "$SRC_DRIVE" "$DST_DRIVE"; do
  if [ ! -b "$d" ]; then
    echo "Error: $d not found. Aborting."
    exit 1
  fi
done

read -rp "This will WIPE ALL DATA on $DST_DRIVE. Continue? [y/N] " confirm
[[ $confirm == [yY] ]] || exit 1

# STEP2: Partition the dst drive
echo "[*] Wiping and partitioning $DST_DRIVE..."
sgdisk --zap-all "$DST_DRIVE"
parted -s "$DST_DRIVE" mklabel gpt
parted -s "$DST_DRIVE" mkpart EFI fat32 1MiB "${EFI_SIZE}"
parted -s "$DST_DRIVE" set 1 esp on
parted -s "$DST_DRIVE" mkpart root ext4 "${EFI_SIZE}" 100%

sleep 5

EFI_PART="${DST_DRIVE}p1"
ROOT_PART="${DST_DRIVE}p2"

# STEP3: Format partitions
echo "[*] Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

# STEP4: Mount target
echo "[*] Mounting new system..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# STEP5: Mount source
echo "[*] Mounting source system..."
mkdir -p /old
mount "${SRC_DRIVE}p2" /old
mount "${SRC_DRIVE}p1" /old/boot || true

# STEP6: Rsync clone
echo "[*] Cloning system via rsync..."
rsync -aAXHv --info=progress2 \
  --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/old/*","/lost+found"} \
  /old/ /mnt/

# STEP7: Chroot fixes
echo "[*] Chrooting into new system..."
arch-chroot /mnt /bin/bash <<'EOF'
set -e
echo "[chroot] Generating fstab..."
genfstab -U / > /etc/fstab

echo "[chroot] Installing bootloader..."
if command -v grub-install >/dev/null 2>&1; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchLinux
  grub-mkconfig -o /boot/grub/grub.cfg
elif command -v bootctl >/dev/null 2>&1; then
  bootctl install
  echo "[!] Reminder: Check /boot/loader/entries/arch.conf root UUID."
else
  echo "[!] No bootlder found. Please install manually."
fi
EOF

# STEP8: Cleanup
echo "[*] Cleaning up..."
umount -R /mnt
umount /old || true

echo "[✓] Clone complete!"
echo "You can now reboot and select the new drive ($DST_DRIVE) in your BIOS/UEFI."
