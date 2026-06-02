#!/bin/sh
#
# 10-config.sh — Nextcloud post-installation configuration.
#
# The official image runs every executable in
# /docker-entrypoint-hooks.d/post-installation/ exactly once, immediately after
# a fresh `occ maintenance:install`, as the www-data user (so `occ` works
# without sudo). We bind-mount this dir read-only from the image's
# /etc/nextcloud/hooks.
#
# It sets the configuration that has NO dedicated environment variable. Keys
# that DO have env vars (DB, Redis host/password, trusted domains/proxies,
# overwrite*) are intentionally NOT set here to avoid drift with the entrypoint.
#
# Idempotent by nature: the image only runs post-installation hooks once, and
# `occ config:system:set` is itself idempotent if it ever re-runs.

set -eu

occ() { php /var/www/html/occ "$@"; }

echo "10-config: applying post-installation system config."

# Memcache: APCu for local, Valkey (Redis protocol) for distributed cache and
# transactional file locking. The Redis host/port/password come from the
# REDIS_HOST* env vars the entrypoint already wrote into config.php.
occ config:system:set memcache.local       --value '\OC\Memcache\APCu'
occ config:system:set memcache.distributed  --value '\OC\Memcache\Redis'
occ config:system:set memcache.locking      --value '\OC\Memcache\Redis'

# Background jobs are driven by the nextcloud-cron.container sidecar (cron.php).
occ background:cron

# Parse national phone numbers (clears an admin setup warning).
occ config:system:set default_phone_region --value '@@NEXTCLOUD_PHONE_REGION@@'

# Run heavy maintenance jobs in the low-load window starting 01:00 UTC
# (value is an hour 0-23; clears the "maintenance window" setup warning).
occ config:system:set maintenance_window_start --type integer --value 1

# --- Previews -----------------------------------------------------------------
# Offload heavy image preview generation to the imaginary backend (data network,
# imaginary:9000). Keep only the lightweight providers in PHP; imaginary handles
# all the bitmap formats. This is the canonical NC list when using imaginary.
occ config:system:set enabledPreviewProviders 0 --value 'OC\Preview\TXT'
occ config:system:set enabledPreviewProviders 1 --value 'OC\Preview\MarkDown'
occ config:system:set enabledPreviewProviders 2 --value 'OC\Preview\OpenDocument'
occ config:system:set enabledPreviewProviders 3 --value 'OC\Preview\Krita'
occ config:system:set enabledPreviewProviders 4 --value 'OC\Preview\Imaginary'
occ config:system:set preview_imaginary_url --value 'http://imaginary:9000'
# Smaller, faster-to-serve previews.
occ config:system:set preview_format --value 'webp'

echo "10-config: done."
