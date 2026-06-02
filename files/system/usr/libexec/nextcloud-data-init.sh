#!/usr/bin/env bash
#
# nextcloud-data-init.sh
#
# Prepares the dedicated Nextcloud data disk (the 2 TB device).
#
# Behaviour:
#   - If a filesystem already labelled "ncdata" exists, do nothing.
#   - Otherwise locate the data disk (a single whole disk >= 1.5 TB that is
#     NOT the OS/boot disk), wipe it, create a GPT + one partition, and
#     format it XFS with label "ncdata".
#
# Safety guards (this WIPES a disk, so it is deliberately conservative):
#   - The OS/boot disk is always excluded.
#   - Only whole disks of type "disk" are considered (no partitions, loops,
#     ram, zram, optical, or floppy devices).
#   - Acts only when EXACTLY ONE candidate of the right size is found.
#     Zero candidates -> skip quietly (mount unit has nofail).
#     Two or more     -> refuse and fail loudly (never guess which to wipe).
#
set -euo pipefail

LABEL="ncdata"
# Minimum size to treat a disk as "the 2 TB data disk". 1.5 TB threshold
# comfortably excludes the 60 GB OS NVMe while matching a ~2 TB disk.
MIN_BYTES=$((1500 * 1000 * 1000 * 1000))

log() { echo "nextcloud-data-init: $*"; }

# Fast path: the labelled filesystem already exists -> nothing to do.
if blkid -L "$LABEL" >/dev/null 2>&1; then
    log "filesystem with label '$LABEL' already present; nothing to do."
    exit 0
fi

# Identify the OS/boot disk so we never touch it. In an ostree/bootc system
# the physical root is mounted at /sysroot; fall back to / then /boot.
boot_part=""
for mp in /sysroot / /boot; do
    src="$(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -b "$src" ]; then
        boot_part="$src"
        break
    fi
done

boot_disk=""
if [ -n "$boot_part" ]; then
    boot_disk="$(lsblk -no PKNAME "$boot_part" 2>/dev/null | head -n1 || true)"
fi

if [ -z "$boot_disk" ]; then
    log "ERROR: could not determine the OS/boot disk; refusing to format anything."
    exit 1
fi
log "OS/boot disk detected as '/dev/$boot_disk' (will be excluded)."

# Find candidate data disks: whole disks, not the boot disk, >= MIN_BYTES.
target=""
while read -r name type; do
    [ "$type" = "disk" ] || continue
    [ "$name" = "$boot_disk" ] && continue

    dev="/dev/$name"
    size="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    [ "$size" -ge "$MIN_BYTES" ] || continue

    if [ -n "$target" ]; then
        log "ERROR: multiple disks >= 1.5 TB found ('$target' and '$dev'); refusing to auto-format."
        exit 1
    fi
    target="$dev"
done < <(lsblk -dno NAME,TYPE)

if [ -z "$target" ]; then
    log "no candidate data disk (>= 1.5 TB) found; skipping (mount is nofail)."
    exit 0
fi

log "preparing data disk '$target' (GPT + single XFS partition, label '$LABEL')."

# Wipe any existing signatures and partition table, then create one partition.
wipefs --all --force "$target"
printf 'label: gpt\n,,L\n' | sfdisk --wipe always "$target"

# Let udev create the partition node.
udevadm settle

# Resolve the first (and only) partition node, handling both sdX1 and nvmeXn1p1 styles.
part=""
for _ in $(seq 1 10); do
    part="$(lsblk -lnpo NAME,TYPE "$target" | awk '$2=="part"{print $1; exit}')"
    [ -n "$part" ] && [ -b "$part" ] && break
    udevadm settle
    sleep 1
done

if [ -z "$part" ] || [ ! -b "$part" ]; then
    log "ERROR: partition device did not appear on '$target'."
    exit 1
fi

mkfs.xfs -f -L "$LABEL" "$part"
udevadm settle

log "done: '$part' formatted XFS with label '$LABEL'."
