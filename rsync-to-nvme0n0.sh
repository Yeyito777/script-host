#!/usr/bin/env bash
#
# Sync the currently-booted filesystem (/) non-destructively into /dev/nvme0n1p2
# using rsync. The target partition is mounted on a temporary directory created
# with mktemp, then unmounted and removed on exit.
#
# NOTE:
#   - This does NOT delete anything on nvme0n1p2 (no --delete).
#   - New and changed files (outside excluded paths) are copied over.
#   - Excludes virtual/temporary filesystems and /boot.
#

set -euo pipefail

SRC="/"
DEV="/dev/nvme0n1p2"

# ---- Safety checks ---------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if [[ ! -b "$DEV" ]]; then
  echo "Block device $DEV does not exist." >&2
  exit 1
fi

# ---- Create temporary mountpoint ------------------------------------------

# Use mktemp to create a unique temporary directory under /mnt
TARGET_MNT="$(mktemp -d /mnt/nvme0n1p2.XXXXXX)"

cleanup() {
  # Best-effort cleanup; don't abort on errors here
  set +e
  sync
  if command -v mountpoint >/dev/null 2>&1; then
    if mountpoint -q "$TARGET_MNT"; then
      umount "$TARGET_MNT"
    fi
  else
    # Fallback: try to unmount assuming it's mounted
    umount "$TARGET_MNT" 2>/dev/null
  fi
  rmdir "$TARGET_MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "Mounting $DEV on $TARGET_MNT ..."
mount "$DEV" "$TARGET_MNT"

# ---- Rsync options & exclusions -------------------------------------------

# Things we *don't* want to copy from the live system:
#  - /boot      : usually its own partition, handled separately
#  - /dev       : device nodes
#  - /proc      : procfs (virtual)
#  - /sys       : sysfs (virtual)
#  - /run       : runtime state
#  - /tmp       : temporary files
#  - /mnt, /media : other mounted filesystems (and our temp mount)
#  - /lost+found : fs recovery area
RSYNC_EXCLUDES=(
  "/boot/*"
  "/dev/*"
  "/proc/*"
  "/sys/*"
  "/run/*"
  "/tmp/*"
  "/mnt/*"
  "/media/*"
  "/lost+found"
)

# Core rsync options:
#  -a  : archive (recursive, perms, times, etc.)
#  -A  : preserve ACLs
#  -X  : preserve extended attributes
#  -H  : preserve hard links
#  -v  : verbose
RSYNC_OPTS=(
  -aAXHv
  --numeric-ids
  --info=progress2
)

echo "Starting non-destructive rsync from $SRC to $DEV (mounted at $TARGET_MNT) ..."
echo

rsync "${RSYNC_OPTS[@]}" \
  "${RSYNC_EXCLUDES[@]/#/--exclude=}" \
  "$SRC" "$TARGET_MNT"

echo
echo "Sync complete. Flushing buffers..."
sync

echo "All done. $DEV has been updated non-destructively."
