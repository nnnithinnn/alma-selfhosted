#!/usr/bin/env bash

set -xeuo pipefail

# Start customizing your image here

# Headless server: boot to multi-user, not graphical (no GUI on this host).
systemctl set-default multi-user.target

### Storage: dedicated 2 TB Nextcloud data disk ###############################
# The 2 TB disk is auto-prepared on first boot (formatted XFS, label "ncdata")
# and mounted at /var/mnt/nextcloud. See:
#   - files/system/usr/libexec/nextcloud-data-init.sh
#   - files/system/usr/lib/systemd/system/nextcloud-data-init.service
#   - files/system/etc/systemd/system/var-mnt-nextcloud.mount
#   - files/system/usr/lib/tmpfiles.d/nextcloud.conf
# Ensure the init helper is executable (cp preserves source perms, but be robust).
chmod 0755 /usr/libexec/nextcloud-data-init.sh

systemctl enable nextcloud-data-init.service
systemctl enable var-mnt-nextcloud.mount

# One-time rootful chown of the data disk's top-level dir so the rootless
# Nextcloud container (www-data uid 33 -> host subuid 100032) can write to it.
# Runs once on first boot after the disk is mounted; see:
#   - files/system/usr/libexec/nextcloud-data-chown.sh
#   - files/system/usr/lib/systemd/system/nextcloud-data-chown.service
chmod 0755 /usr/libexec/nextcloud-data-chown.sh
systemctl enable nextcloud-data-chown.service

# The Nextcloud first-run occ hook is mounted read-only into the container's
# /docker-entrypoint-hooks.d/; the image only executes hooks with the exec bit.
chmod 0755 /etc/nextcloud/hooks/post-installation/10-config.sh

# App install/config helper (driven by the nextcloud-apps-init user service,
# enabled via a baked symlink in /etc/systemd/user/default.target.wants/).
# Installs the non-bundled apps (notify_push, preview_generator, PIM) on first
# boot; idempotent and retryable. See:
#   - files/system/usr/libexec/nextcloud-apps-init.sh
#   - files/system/etc/systemd/user/nextcloud-apps-init.service
# The preview_generator timer (nextcloud-preview-generator.timer) is enabled via
# a baked symlink in /etc/systemd/user/timers.target.wants/.
chmod 0755 /usr/libexec/nextcloud-apps-init.sh

### Database tier: rootless secrets bootstrap ################################
# db-secrets-init generates the Postgres/Valkey passwords as rootless podman
# secrets on first boot (in nithin's lingered user session). It is enabled via
# a baked symlink in /etc/systemd/user/default.target.wants/ because
# `systemctl --user enable` cannot run at build time. See:
#   - files/system/usr/libexec/db-secrets-init.sh
#   - files/system/etc/systemd/user/db-secrets-init.service
chmod 0755 /usr/libexec/db-secrets-init.sh
