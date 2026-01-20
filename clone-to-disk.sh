#!/usr/bin/env bash
set -euo pipefail

TARGET_DISK="/dev/sda"
TARGET_EFI="${TARGET_DISK}1"
TARGET_ROOT="${TARGET_DISK}2"

MODE="full"
case "${1:-}" in
    --update|-u)       MODE="update" ;;
    --soft-update|-s)  MODE="soft-update" ;;
esac

if [[ "$MODE" == "update" ]]; then
    echo "=== UPDATE MODE ==="
    echo "Will sync changes to existing clone on ${TARGET_DISK} (deletes removed files)"
    read -rp "Continue? [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }
elif [[ "$MODE" == "soft-update" ]]; then
    echo "=== SOFT UPDATE MODE ==="
    echo "Will sync changes to existing clone on ${TARGET_DISK} (keeps extra files)"
    read -rp "Continue? [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }
else
    echo "=== WARNING ==="
    echo "This will ERASE ${TARGET_DISK} COMPLETELY."
    read -rp "Type YES to continue: " ok
    [[ "$ok" == "YES" ]] || { echo "Aborted"; exit 1; }

    echo "== Creating fresh partitions =="
    sudo wipefs -a "$TARGET_DISK"
    sudo sgdisk --zap-all "$TARGET_DISK"

    # EFI partition (512MB)
    sudo sgdisk -n 1:2048:+512M -t 1:ef00 "$TARGET_DISK"

    # Root partition (rest of disk)
    sudo sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"

    sudo partprobe "$TARGET_DISK"
    sleep 2

    echo "== Formatting target partitions =="
    sudo mkfs.vfat -F32 "$TARGET_EFI"
    sudo mkfs.ext4 -F "$TARGET_ROOT"
fi

echo "== Mounting target =="
TGT_MNT=$(mktemp -d)
sudo mount "$TARGET_ROOT" "$TGT_MNT"
sudo mkdir -p "$TGT_MNT/boot/efi"
sudo mount "$TARGET_EFI" "$TGT_MNT/boot/efi"

echo "== Cloning root filesystem with rsync =="
RSYNC_OPTS=(-aAXHv --exclude={"/dev/*","/proc/*","/sys/*","/run/*","/tmp/*","/mnt/*","/media/*","/lost+found","/home/yeyito/.cache/*"})
if [[ "$MODE" != "full" ]]; then
    # Preserve USB-specific boot config (has USB's UUIDs, not source disk's)
    RSYNC_OPTS+=(--exclude="/etc/fstab" --exclude="/boot/grub/grub.cfg")
fi
if [[ "$MODE" == "update" ]]; then
    RSYNC_OPTS+=(--delete)
fi
set +e
sudo rsync "${RSYNC_OPTS[@]}" / "$TGT_MNT"/
rsync_exit=$?
set -e
# Acceptable exit codes for live system clones:
#   0  - Success
#   23 - Partial transfer (some files couldn't be read/written)
#   24 - Some files vanished before transfer
if [[ $rsync_exit -ne 0 && $rsync_exit -ne 23 && $rsync_exit -ne 24 ]]; then
    echo "rsync failed with exit code $rsync_exit"
    exit $rsync_exit
fi
if [[ $rsync_exit -ne 0 ]]; then
    echo "rsync completed with warnings (exit code $rsync_exit) - continuing"
fi

if [[ "$MODE" == "full" ]]; then
    echo "== Recreate fstab based on new UUIDs =="
    TGT_UUID_ROOT=$(sudo blkid -s UUID -o value "$TARGET_ROOT")
    TGT_UUID_EFI=$(sudo blkid -s UUID -o value "$TARGET_EFI")

    cat <<EOF | sudo tee "$TGT_MNT/etc/fstab"
UUID=$TGT_UUID_ROOT / ext4 defaults,noatime 0 1
UUID=$TGT_UUID_EFI  /boot/efi vfat umask=0077 0 1
EOF

    echo "== Bind-mounting for chroot =="
    for i in proc sys dev run; do
        sudo mount --bind /$i "$TGT_MNT"/$i
    done

    echo "== Ensuring protective kernel parameters =="
    # Add amdgpu recovery flags if not present (harmless on non-AMD systems)
    if ! grep -q "amdgpu.gpu_recovery" "$TGT_MNT/etc/default/grub"; then
        sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amdgpu.gpu_recovery=1 amdgpu.runpm=0"/' "$TGT_MNT/etc/default/grub"
    fi

    echo "== Installing bootloader (GRUB/EFI) =="
    sudo chroot "$TGT_MNT" bash -c "
        set -e
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=USBClone --removable
        grub-mkconfig -o /boot/grub/grub.cfg
    "

    for i in run dev sys proc; do
        sudo umount "$TGT_MNT"/$i
    done
fi

echo "== Cleaning up =="
sudo umount "$TGT_MNT/boot/efi"
sudo umount "$TGT_MNT"
rmdir "$TGT_MNT"

echo "=== Done! ==="
