#!/usr/bin/env bash
#
# db-secrets-init.sh — generate the database-tier credentials as rootless
# podman secrets, owned by the app user.
#
# Runs once, early in the app user's (lingered) user systemd session, BEFORE the
# postgres/valkey quadlets start (they order After=db-secrets-init.service).
# The secrets are stored in the app user's persistent container storage under /var,
# so they survive reboots and are generated exactly once.
#
# Secrets are NEVER baked into the image. Each is a 32-byte base64 random value.
# Podman mounts them into the consuming containers as tmpfs files labeled
# container_file_t (no manual SELinux work needed).

set -euo pipefail

# Generate a podman secret from random bytes if it does not already exist.
ensure_secret() {
	local name="$1"
	if podman secret exists "$name"; then
		echo "db-secrets-init: secret '$name' already present; skipping."
		return 0
	fi
	echo "db-secrets-init: creating secret '$name'."
	# 32 random bytes, base64, no newline (passwords must not contain a newline).
	openssl rand -base64 32 | tr -d '\n' | podman secret create "$name" - >/dev/null
}

ensure_secret postgres_password
ensure_secret valkey_password
# Nextcloud's initial admin password (user the app user). Consumed via
# NEXTCLOUD_ADMIN_PASSWORD_FILE only during first-run install; afterwards the
# credential lives in Nextcloud's own DB. Generated once, never baked.
ensure_secret nextcloud_admin_password

echo "db-secrets-init: done."
