#!/usr/bin/env bash
#
# nextcloud-data-chown.sh
#
# One-time, rootful ownership fix for the Nextcloud user-data directory on the
# dedicated 2 TB disk (/var/mnt/nextcloud).
#
# Why this exists / why it must be root:
#   Nextcloud runs ROOTLESS as the app user, whose subordinate UID range is
#   100000-165535 (/etc/subuid). Inside the container www-data is uid 33, which
#   maps to host uid base+33-1 = 100032. The container must own the data dir to
#   write into it. Only real root can chown a root-owned XFS mount to a subuid
#   (the app user cannot chown to a uid it merely "owns" via the map, and rootless
#   `podman unshare` sees the root-owned mount as `nobody`). The `:idmap` volume
#   flag is rootful-only and `:U` would recursively chown 2 TB on every start —
#   both rejected. Hence this small rootful oneshot.
#
# Idempotency:
#   Guarded by a stamp file AND by the systemd unit's ConditionPathExists, so it
#   runs exactly once. The chown targets only the mount's top-level dir (not a
#   recursive 2 TB walk); the container's entrypoint owns everything it creates
#   underneath as www-data thereafter.
#
set -euo pipefail

DATA_DIR="/var/mnt/nextcloud"
STAMP="/var/lib/nextcloud-data-chown.done"
CONTAINER_UID=33   # www-data inside the official Nextcloud image

log() { echo "nextcloud-data-chown: $*"; }

if [ -e "$STAMP" ]; then
    log "stamp '$STAMP' present; nothing to do."
    exit 0
fi

# The mount must be present and be the dedicated disk (nofail mount may be
# absent if the 2 TB disk is missing) — refuse to chown the fallback /var dir.
if ! mountpoint -q "$DATA_DIR"; then
    log "ERROR: '$DATA_DIR' is not a mountpoint (data disk absent?); refusing."
    exit 1
fi

# Resolve the app user's subuid base from /etc/subuid. The entry is always
# written as UID 1000 (not by name) by 20-users.sh at build time.
subline="$(awk -F: '$1=="1000" {print; exit}' /etc/subuid)"
if [ -z "${subline:-}" ]; then
    log "ERROR: no subuid range for the app user in /etc/subuid; refusing."
    exit 1
fi
base="$(echo "$subline" | cut -d: -f2)"

host_uid=$(( base + CONTAINER_UID - 1 ))
log "subuid base=$base -> container uid $CONTAINER_UID maps to host uid $host_uid."

chown "$host_uid:$host_uid" "$DATA_DIR"
log "chowned '$DATA_DIR' to $host_uid:$host_uid."

# Persist the stamp so we never run again (survives reboots: /var is persistent).
mkdir -p "$(dirname "$STAMP")"
: > "$STAMP"
log "done; wrote stamp '$STAMP'."
