#!/usr/bin/env bash
#
# nextcloud-apps-init.sh — install & configure the non-bundled Nextcloud apps.
#
# Runs in the app user's (lingered) user systemd session as a oneshot, AFTER the
# Nextcloud app container is up. It is deliberately IDEMPOTENT and has NO stamp:
# it re-checks on every boot and only installs apps that are missing, so a
# transient app-store/network failure on first boot self-heals on the next boot
# (or on `systemctl --user restart nextcloud-apps-init`).
#
# App downloads require first-boot OUTBOUND access to apps.nextcloud.com. Only
# inbound is firewalled, so egress is available.
#
# occ is driven inside the rootless app container via `podman exec`.
set -euo pipefail

CONFIG=/etc/selfhosted/config.env
if [[ ! -f "$CONFIG" ]]; then
    echo "nextcloud-apps-init: ERROR: $CONFIG not found — system not configured; skipping." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

CONTAINER="systemd-nextcloud"

# Apps to ensure are installed (app-store IDs). Bundled apps (e.g. photos,
# dashboard) are NOT listed — they ship in the image.
APPS=(
	notify_push        # High Performance Backend (push server runs as a sidecar)
	preview_generator  # pre-generates previews (driven by a user timer)
	contacts           # PIM
	calendar           # PIM
	mail               # PIM
	tasks              # PIM
	notes              # PIM
	richdocuments      # Nextcloud Office (Collabora Online / CODE frontend)
)

log() { echo "nextcloud-apps-init: $*"; }

occ() { podman exec --user www-data "$CONTAINER" php occ "$@"; }

# Wait until Nextcloud is installed and answering occ (first boot runs the
# install + image pull, which can take a while).
log "waiting for Nextcloud to finish installing…"
for _ in $(seq 1 120); do
	if occ status 2>/dev/null | grep -q 'installed: true'; then
		log "Nextcloud is installed."
		break
	fi
	sleep 10
done

if ! occ status 2>/dev/null | grep -q 'installed: true'; then
	log "ERROR: Nextcloud not installed after timeout; will retry next boot."
	exit 1
fi

# Snapshot the currently-enabled app list once.
enabled="$(occ app:list --output=json 2>/dev/null || echo '{}')"

ensure_app() {
	local app="$1"
	if printf '%s' "$enabled" | grep -q "\"$app\""; then
		log "app '$app' already present; skipping."
		return 0
	fi
	log "installing app '$app'…"
	# app:install downloads from the app store and enables it. Tolerate failure
	# of a single app so the others still get installed; the missing one retries
	# on the next boot.
	if occ app:install "$app"; then
		log "app '$app' installed."
	else
		log "WARNING: failed to install '$app' (will retry next boot)."
	fi
}

for app in "${APPS[@]}"; do
	ensure_app "$app"
done

# --- App-specific configuration (depends on the app being installed) ---------

# notify_push: point the app at the public push endpoint Caddy proxies to the
# sidecar. We set base_endpoint directly instead of `notify_push:setup`, whose
# self-test calls the public URL (impossible behind QEMU NAT / before the VPS
# has a real cert). The admin "High performance backend" check validates it at
# runtime once reachable.
if printf '%s' "$enabled" | grep -q '"notify_push"' || occ app:list --output=json 2>/dev/null | grep -q '"notify_push"'; then
	occ config:app:set notify_push base_endpoint --value "https://${NEXTCLOUD_HOST}/push" || \
		log "WARNING: could not set notify_push base_endpoint (will retry next boot)."
fi

# richdocuments (Nextcloud Office): point it at the Collabora CODE backend. With
# the same-domain layout, Collabora is reachable at the Nextcloud host itself
# (Caddy routes the COOL paths), so the WOPI URL is just the public base URL.
# wopi_allowlist restricts which hosts may issue WOPI callbacks to Collabora's
# container network (the pinned web subnet). The live discovery handshake only
# succeeds once a real cert/DNS exists, so this is validated at VPS cutover.
if printf '%s' "$enabled" | grep -q '"richdocuments"' || occ app:list --output=json 2>/dev/null | grep -q '"richdocuments"'; then
	occ config:app:set richdocuments wopi_url        --value "https://${NEXTCLOUD_HOST}" || \
		log "WARNING: could not set richdocuments wopi_url (will retry next boot)."
	occ config:app:set richdocuments public_wopi_url --value "https://${NEXTCLOUD_HOST}" || \
		log "WARNING: could not set richdocuments public_wopi_url (will retry next boot)."
	occ config:app:set richdocuments wopi_allowlist  --value "${WEB_SUBNET}" || \
		log "WARNING: could not set richdocuments wopi_allowlist (will retry next boot)."
fi

log "done."
