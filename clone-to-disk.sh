#!/usr/bin/env bash
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

# Derive partition device path from whole-disk path + partition number.
#   nvme0n1  + 1 → nvme0n1p1   (name ends in digit  → 'p' separator)
#   mmcblk0  + 1 → mmcblk0p1   (same rule)
#   sda      + 1 → sda1        (name ends in letter → direct append)
part() { [[ "$1" =~ [0-9]$ ]] && echo "${1}p${2}" || echo "${1}${2}"; }


ask_yn() {
    local prompt="$1" default="${2:-y}" answer
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " answer
        [[ "${answer:-y}" =~ ^[Yy]$ ]]
    else
        read -rp "$prompt [y/N]: " answer
        [[ "${answer:-n}" =~ ^[Yy]$ ]]
    fi
}

valid_alias() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && [[ ! "$1" =~ -$ ]]
}

append_unique_line() {
    local line="$1" file="$2"
    grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

# ── Clone mode (from CLI flag) ────────────────────────────────────────────────

MODE="full"
case "${1:-}" in
    --update|-u)       MODE="update" ;;
    --soft-update|-s)  MODE="soft-update" ;;
esac

# ── SSH network variables (questions are asked after target selection) ────────

ACTUAL_USER="${SUDO_USER:-$(id -un)}"
ACTUAL_HOME=$(eval echo "~${ACTUAL_USER}")
SOURCE_ALIAS=$(cat /etc/hostname 2>/dev/null || uname -n)
SOURCE_ALIAS=${SOURCE_ALIAS%%.*}
SETUP_CLONE_SSH="no"
CLONE_ALIAS=""
SOURCE_NODE_KEY="${ACTUAL_HOME}/.ssh/id_ed25519_${SOURCE_ALIAS}"

# ── Detect source (currently booted) disk ─────────────────────────────────────

SRC_DEV=$(findmnt -no SOURCE /)
SRC_DISK=$(lsblk -npo PKNAME "$SRC_DEV" | head -1 | tr -d ' ')
SRC_SIZE=$(lsblk -dno SIZE "$SRC_DISK" | tr -d ' ')
SRC_MODEL=$(lsblk -dno MODEL "$SRC_DISK" | xargs)
SRC_USED=$(df -h --output=used / | tail -1 | xargs)
SRC_USED_B=$(df -B1 --output=used / | tail -1 | tr -d ' ')

# ── Discover candidate target disks ──────────────────────────────────────────

TGTS=(); TGT_SZ=(); TGT_MD=(); TGT_WR=(); TGT_BY=()

while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    [[ "$dev" == "$SRC_DISK" ]] && continue
    [[ "$dev" =~ ^/dev/(loop|zram|sr|fd) ]] && continue

    TGTS+=("$dev")
    TGT_SZ+=("$(lsblk -dno SIZE "$dev" | tr -d ' ')")
    TGT_MD+=("$(lsblk -dno MODEL "$dev" | xargs)")
    TGT_BY+=("$(lsblk -bdno SIZE "$dev" | tr -d ' ')")

    if lsblk -lno MOUNTPOINT "$dev" 2>/dev/null | grep -q '/'; then
        TGT_WR+=("mounted")
    else
        TGT_WR+=("")
    fi
done < <(lsblk -dpno NAME | sort)

if [[ ${#TGTS[@]} -eq 0 ]]; then
    echo "No candidate target disks found (only the boot disk is present)."
    exit 1
fi

# ── Interactive target selector ───────────────────────────────────────────────

sel=0
n=${#TGTS[@]}

# Terminal styling (degrade gracefully when not a tty)
if [[ -t 1 ]]; then
    B=$(tput bold);  D=$(tput dim)
    CC=$(tput setaf 6); CG=$(tput setaf 2)
    CY=$(tput setaf 3); CR=$(tput setaf 1)
    R=$(tput sgr0);  EL=$'\033[K'
else
    B="" D="" CC="" CG="" CY="" CR="" R="" EL=""
fi

# Menu height: blank + title + blank + source + blank + N disks + blank + help + blank
MENU_H=$((8 + n))

draw_menu() {
    printf "%s\n"   "$EL"
    printf "  %s── Select target disk for cloning ──%s%s\n" "$B" "$R" "$EL"
    printf "%s\n"   "$EL"
    printf "  Source: %s%s%s · %s · %s  (%s used)%s\n" \
        "$CC" "$SRC_DISK" "$R" "$SRC_SIZE" "$SRC_MODEL" "$SRC_USED" "$EL"
    printf "%s\n"   "$EL"

    for i in "${!TGTS[@]}"; do
        if [[ $i -eq $sel ]]; then
            printf "  %s▸%s %s%-14s  %7s  %s%s" \
                "$CG" "$R" "$B" "${TGTS[$i]}" "${TGT_SZ[$i]}" "${TGT_MD[$i]}" "$R"
        else
            printf "  %s  %-14s  %7s  %s%s" \
                "$D" "${TGTS[$i]}" "${TGT_SZ[$i]}" "${TGT_MD[$i]}" "$R"
        fi
        if [[ -n "${TGT_WR[$i]}" ]]; then
            printf "  %s⚠ %s%s" "$CY" "${TGT_WR[$i]}" "$R"
        fi
        printf "%s\n" "$EL"
    done

    printf "%s\n"   "$EL"
    printf "  %s↑↓/jk: move · Enter: select · q: quit%s%s\n" "$D" "$R" "$EL"
    printf "%s\n"   "$EL"
}

read_key() {
    local k
    IFS= read -rsn1 k 2>/dev/null || true
    if [[ "$k" == $'\x1b' ]]; then
        local seq=""
        IFS= read -rsn2 -t 0.1 seq 2>/dev/null || true
        case "$seq" in
            '[A') echo up   ;; '[B') echo down ;;
            *)    echo other ;;
        esac
    else
        case "$k" in
            k)  echo up   ;; j)  echo down  ;;
            q)  echo quit ;; '') echo enter  ;;
            *)  echo other ;;
        esac
    fi
}

# Hide cursor while the menu is active; restore on any exit.
# Ctrl+C should abort, not merely restore the cursor and continue reads/prompts.
tput civis 2>/dev/null || true
show_cursor() { tput cnorm 2>/dev/null || true; }
abort() { show_cursor; echo; echo "Aborted."; exit 130; }
trap show_cursor EXIT
trap abort INT TERM

draw_menu

while true; do
    key=$(read_key)
    case "$key" in
        up)    if [[ $sel -gt 0 ]];          then sel=$((sel - 1)); fi ;;
        down)  if [[ $sel -lt $((n - 1)) ]]; then sel=$((sel + 1)); fi ;;
        enter) break ;;
        quit)  show_cursor; echo "Aborted."; exit 0 ;;
    esac
    printf "\033[%dA" "$MENU_H"
    draw_menu
done

show_cursor

# ── Set target from selection ─────────────────────────────────────────────────

TARGET_DISK="${TGTS[$sel]}"
TARGET_EFI=$(part "$TARGET_DISK" 1)
TARGET_ROOT=$(part "$TARGET_DISK" 2)


# ── Target identity / SSH-network helpers ─────────────────────────────────────

sanitize_target_identity() {
    echo "== Sanitizing target machine identity =="

    # Server identity must be unique per booted machine.
    sudo rm -f "$TGT_MNT"/etc/ssh/ssh_host_*
    sudo rm -f "$TGT_MNT"/etc/ssh/sshd_config.d/00-hardening.conf

    # Inbound trust policy is rebuilt below if SSH networking is enabled.
    sudo rm -f "$TGT_MNT"/home/*/.ssh/authorized_keys 2>/dev/null || true
    sudo rm -f "$TGT_MNT"/root/.ssh/authorized_keys 2>/dev/null || true

    # Outbound private keys must not be inherited by clones.
    sudo find "$TGT_MNT/home" "$TGT_MNT/root" -path '*/.ssh/*' -type f \
        \( -name 'id_*' -o -name '*_ed25519' -o -name '*_rsa' -o -name '*_ecdsa' -o -name 'google_compute_engine' \) \
        -delete 2>/dev/null || true
    sudo bash -c '
        root="$1"
        find "$root/home" "$root/root" -path "*/.ssh/*" -type f -print0 2>/dev/null |
        while IFS= read -r -d "" f; do
            if head -n 1 "$f" 2>/dev/null | grep -Eq "BEGIN (OPENSSH|RSA|DSA|EC) PRIVATE KEY"; then
                rm -f "$f" "$f.pub"
            fi
        done
    ' _ "$TGT_MNT"

    # OS identity/randomness should also be unique.
    sudo truncate -s 0 "$TGT_MNT/etc/machine-id" 2>/dev/null || sudo touch "$TGT_MNT/etc/machine-id"
    sudo rm -f "$TGT_MNT/var/lib/dbus/machine-id" 2>/dev/null || true
    sudo rm -f "$TGT_MNT/var/lib/systemd/random-seed" 2>/dev/null || true
}

disable_target_ssh_node() {
    echo "== Leaving target outside SSH network =="
    sudo systemctl --root="$TGT_MNT" disable sshd ssh fail2ban 2>/dev/null || true
    sudo rm -f "$TGT_MNT"/etc/systemd/system/multi-user.target.wants/sshd.service \
               "$TGT_MNT"/etc/systemd/system/multi-user.target.wants/ssh.service \
               "$TGT_MNT"/etc/systemd/system/multi-user.target.wants/fail2ban.service 2>/dev/null || true
}

configure_target_ssh_node() {
    echo "== Configuring target as SSH-network node: ${CLONE_ALIAS} =="

    local uid gid target_home target_ssh target_key target_auth source_pub clone_pub tmp_auth hardening
    uid=$(id -u "$ACTUAL_USER")
    gid=$(id -g "$ACTUAL_USER")
    target_home="$TGT_MNT/home/$ACTUAL_USER"
    target_ssh="$target_home/.ssh"
    target_key="$target_ssh/id_ed25519_${CLONE_ALIAS}"
    target_auth="$target_ssh/authorized_keys"
    hardening="$TGT_MNT/etc/ssh/sshd_config.d/00-hardening.conf"

    if [[ ! -d "$target_home" ]]; then
        echo "Target user home missing: $target_home"
        exit 1
    fi
    if [[ ! -x "$TGT_MNT/usr/bin/sshd" ]]; then
        echo "Target does not have openssh installed. Run setup-ssh.sh on the source first."
        exit 1
    fi
    if [[ ! -e "$TGT_MNT/usr/lib/systemd/system/fail2ban.service" && ! -e "$TGT_MNT/etc/systemd/system/fail2ban.service" ]]; then
        echo "Target does not have fail2ban installed. Run setup-ssh.sh on the source first."
        exit 1
    fi

    printf '%s\n' "$CLONE_ALIAS" | sudo tee "$TGT_MNT/etc/hostname" >/dev/null

    sudo install -d -m 755 "$TGT_MNT/etc/ssh/sshd_config.d"
    # Generate target host keys from the host side. A raw rsync clone has an
    # empty /dev, so chrooted ssh-keygen may fail opening /dev/null.
    sudo ssh-keygen -A -f "$TGT_MNT"

    sudo install -d -m 700 -o "$uid" -g "$gid" "$target_ssh"
    sudo rm -f "$target_key" "$target_key.pub"
    sudo ssh-keygen -t ed25519 -C "${ACTUAL_USER}@${CLONE_ALIAS}" -f "$target_key" -N "" >/dev/null
    sudo chown "$uid:$gid" "$target_key" "$target_key.pub"
    sudo chmod 600 "$target_key"
    sudo chmod 644 "$target_key.pub"

    source_pub=$(cat "${SOURCE_NODE_KEY}.pub")
    clone_pub=$(sudo cat "$target_key.pub")

    tmp_auth=$(mktemp)
    if [[ -f "$ACTUAL_HOME/.ssh/authorized_keys" ]]; then
        cat "$ACTUAL_HOME/.ssh/authorized_keys" > "$tmp_auth"
    fi
    append_unique_line "$source_pub" "$tmp_auth"
    append_unique_line "$clone_pub" "$tmp_auth"
    awk 'NF && !seen[$0]++' "$tmp_auth" | sudo tee "$target_auth" >/dev/null
    rm -f "$tmp_auth"
    sudo chown "$uid:$gid" "$target_auth"
    sudo chmod 600 "$target_auth"

    cat <<EOF | sudo tee "$hardening" >/dev/null
# SSH network node — key-only, internet-facing
# Generated by clone-to-disk.sh on $(date +%Y-%m-%d)
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers ${ACTUAL_USER}
MaxAuthTries 3
X11Forwarding no
EOF

    cat <<'EOF' | sudo tee "$TGT_MNT/etc/fail2ban/jail.local" >/dev/null
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
EOF

    sudo mkdir -p "$TGT_MNT/run/sshd"
    sudo env TGT_MNT="$TGT_MNT" unshare --mount bash <<'SSH_VALIDATE_NS'
        set -e
        mount --bind /dev "$TGT_MNT/dev"
        chroot "$TGT_MNT" /usr/bin/sshd -t
SSH_VALIDATE_NS
    sudo systemctl --root="$TGT_MNT" enable sshd fail2ban >/dev/null

    sudo install -d -m 700 -o "$uid" -g "$gid" "$ACTUAL_HOME/.ssh"
    sudo touch "$ACTUAL_HOME/.ssh/authorized_keys"
    sudo chown "$uid:$gid" "$ACTUAL_HOME/.ssh/authorized_keys"
    sudo chmod 600 "$ACTUAL_HOME/.ssh/authorized_keys"
    if ! grep -qxF "$clone_pub" "$ACTUAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
        printf '%s\n' "$clone_pub" | sudo tee -a "$ACTUAL_HOME/.ssh/authorized_keys" >/dev/null
    fi

    echo "SSH node configured:"
    echo "  hostname:        ${CLONE_ALIAS}"
    echo "  target key:      /home/${ACTUAL_USER}/.ssh/id_ed25519_${CLONE_ALIAS}"
    echo "  source now trusts ${CLONE_ALIAS}'s public key"
}

# ── Post-selection safety checks ─────────────────────────────────────────────

# Refuse if any partition on the target is currently mounted
if [[ -n "${TGT_WR[$sel]}" ]]; then
    printf "\n  %s%sError:%s %s has mounted partitions. Unmount them first:\n\n" "$CR" "$B" "$R" "$TARGET_DISK"
    lsblk -po NAME,SIZE,MOUNTPOINT "$TARGET_DISK" | sed 's/^/    /'
    echo ""
    exit 1
fi

# Warn if source used space exceeds target disk capacity
if [[ "$SRC_USED_B" -gt "${TGT_BY[$sel]}" ]]; then
    printf "\n  %s%sWarning:%s Source uses %s but target is only %s.\n" "$CY" "$B" "$R" "$SRC_USED" "${TGT_SZ[$sel]}"
    read -rp "  This clone will likely fail. Continue anyway? [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

printf "\n  Selected: %s%s%s (%s · %s)\n" "$B" "$TARGET_DISK" "$R" "${TGT_SZ[$sel]}" "${TGT_MD[$sel]}"
printf "  Partitions: EFI=%s  Root=%s\n\n" "$TARGET_EFI" "$TARGET_ROOT"

# ── SSH network setup questions (after target selection, applied after rsync) ──

if ask_yn "Setup SSH for the cloned machine?" "y"; then
    SETUP_CLONE_SSH="yes"
    while true; do
        read -rp "Name/alias for the cloned machine: " CLONE_ALIAS
        if valid_alias "$CLONE_ALIAS"; then
            break
        fi
        echo "Use letters/numbers/dashes only; must not start or end with dash."
    done

    if [[ ! -f "${SOURCE_NODE_KEY}.pub" ]]; then
        echo "Missing source node key: ${SOURCE_NODE_KEY}.pub"
        echo "Run setup-ssh.sh on this source machine first, then clone again."
        exit 1
    fi
fi

# ── Confirmation & partitioning ───────────────────────────────────────────────

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
TGT_MNT="/mnt/clone-target"
sudo mkdir -p "$TGT_MNT"
sudo mount "$TARGET_ROOT" "$TGT_MNT"
sudo mkdir -p "$TGT_MNT/boot/efi"
sudo mount "$TARGET_EFI" "$TGT_MNT/boot/efi"

echo "== Cloning root filesystem with rsync =="
RSYNC_OPTS=(
    -aAXHv --stats --filter=': .rsync-filter'
    --exclude={"/dev/*","/proc/*","/sys/*","/run/*","/tmp/*","/mnt/*","/media/*","/lost+found","/swapfile"}
    # Never clone machine/server identity or SSH-network secrets.
    --exclude="/etc/ssh/ssh_host_*"
    --exclude="/etc/ssh/sshd_config.d/00-hardening.conf"
    --exclude="/etc/machine-id"
    --exclude="/var/lib/dbus/machine-id"
    --exclude="/var/lib/systemd/random-seed"
    --exclude="/home/*/.ssh/authorized_keys"
    --exclude="/home/*/.ssh/id_*"
    --exclude="/home/*/.ssh/*_ed25519"
    --exclude="/home/*/.ssh/*_rsa"
    --exclude="/home/*/.ssh/*_ecdsa"
    --exclude="/home/*/.ssh/google_compute_engine"
    --exclude="/root/.ssh/*"
    --exclude="/etc/systemd/system/*/sshd.service"
)
if [[ "$MODE" != "full" ]]; then
    # Preserve target-specific boot config (UUIDs, GRUB install, EFI bootloader)
    RSYNC_OPTS+=(--exclude="/etc/fstab" --exclude="/boot/grub/*" --exclude="/boot/efi/*")
fi
if [[ "$MODE" == "update" ]]; then
    RSYNC_OPTS+=(--delete)
fi
RSYNC_LOG=$(mktemp)
CLONE_START=$SECONDS
set +e
sudo rsync "${RSYNC_OPTS[@]}" / "$TGT_MNT"/ 2>&1 | tee "$RSYNC_LOG"
rsync_exit=${PIPESTATUS[0]}
set -e
CLONE_SECS=$((SECONDS - CLONE_START))
# Acceptable exit codes for live system clones:
#   0  - Success
#   23 - Partial transfer (some files couldn't be read/written)
#   24 - Some files vanished before transfer
if [[ $rsync_exit -ne 0 && $rsync_exit -ne 23 && $rsync_exit -ne 24 ]]; then
    echo "rsync failed with exit code $rsync_exit"
    rm -f "$RSYNC_LOG"
    exit $rsync_exit
fi
if [[ $rsync_exit -ne 0 ]]; then
    echo "rsync completed with warnings (exit code $rsync_exit) - continuing"
fi

sanitize_target_identity
if [[ "$SETUP_CLONE_SSH" == "yes" ]]; then
    configure_target_ssh_node
else
    disable_target_ssh_node
fi

echo "== Stripping hardware-specific fields from NetworkManager profiles =="
sudo sed -i '/^interface-name=/d;/^mac-address=/d;/^cloned-mac-address=/d' "$TGT_MNT"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true

if [[ "$MODE" == "full" ]]; then
    echo "== Recreate fstab based on new UUIDs =="
    TGT_UUID_ROOT=$(sudo blkid -s UUID -o value "$TARGET_ROOT")
    TGT_UUID_EFI=$(sudo blkid -s UUID -o value "$TARGET_EFI")

    cat <<EOF | sudo tee "$TGT_MNT/etc/fstab"
UUID=$TGT_UUID_ROOT / ext4 defaults,noatime 0 1
UUID=$TGT_UUID_EFI  /boot/efi vfat umask=0077 0 1
/swapfile none swap sw 0 0
EOF

    echo "== Creating swapfile on target =="
    sudo fallocate -l 16G "$TGT_MNT/swapfile"
    sudo chmod 600 "$TGT_MNT/swapfile"
    sudo mkswap "$TGT_MNT/swapfile"

    echo "== Chroot setup (isolated mount namespace) =="
    sudo env TGT_MNT="$TGT_MNT" unshare --mount bash <<'CHROOT_NS'
        set -e
        for i in proc sys dev run; do
            mount --bind /$i "$TGT_MNT"/$i
        done

        echo "== Ensuring protective kernel parameters =="
        if ! grep -q "amdgpu.gpu_recovery" "$TGT_MNT/etc/default/grub"; then
            sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amdgpu.gpu_recovery=1 amdgpu.runpm=0"/' "$TGT_MNT/etc/default/grub"
        fi

        echo "== Installing bootloader (GRUB/EFI) =="
        chroot "$TGT_MNT" bash -c "
            set -e
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=USBClone --removable
            grub-mkconfig -o /boot/grub/grub.cfg
        "
CHROOT_NS
fi

echo "== Cleaning up =="
sudo umount "$TGT_MNT/boot/efi"
sudo umount "$TGT_MNT"
sudo rmdir "$TGT_MNT"

CLONE_BYTES=$(grep "Total transferred file size:" "$RSYNC_LOG" | grep -oP '[\d,]+' | head -1 | tr -d ',')
rm -f "$RSYNC_LOG"
CLONE_GB=$(awk "BEGIN {printf \"%.2f\", ${CLONE_BYTES:-0} / 1073741824}")
CLONE_GB_SEC=$(awk "BEGIN {s=${CLONE_SECS:-0}; printf \"%.2f\", (s>0) ? (${CLONE_BYTES:-0}/1073741824)/s : 0}")
CLONE_MB_SEC=$(awk "BEGIN {s=${CLONE_SECS:-0}; printf \"%.2f\", (s>0) ? (${CLONE_BYTES:-0}/1048576)/s : 0}")
CLONE_MIN=$((CLONE_SECS / 60))
CLONE_SEC=$((CLONE_SECS % 60))

echo "=== Clone Summary ==="
echo "Time taken: ${CLONE_MIN}m ${CLONE_SEC}s"
echo "Data cloned: ${CLONE_GB} GB"
echo "Speed: ${CLONE_MB_SEC} MB/s"
echo ""
echo "=== Done! ==="
