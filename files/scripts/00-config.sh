#!/usr/bin/env bash
#
# 00-config.sh — apply user customizations from config.env to the baked files.
#
# build.sh sources config.env with `set -a`, so every key is exported into this
# script's environment. Here we:
#   1. Replace @@TOKEN@@ placeholders in the baked config files with their
#      values (sed, NOT envsubst, so shell `$vars` in scripts are left alone).
#   2. Rename the SSH authorized-keys file to the login name, since sshd is
#      configured with `AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u`.
#   3. Fail the build if any unsubstituted @@TOKEN@@ remains.

set -xeuo pipefail

# Every customizable token. Each MUST be defined in config.env (set -u catches
# omissions via the indirect expansion below).
TOKENS=(
  APP_USER NEXTCLOUD_ADMIN_USER
  DOMAIN HEADSCALE_HOST NEXTCLOUD_HOST MAGICDNS_BASE_DOMAIN ACME_EMAIL
  NEXTCLOUD_PHONE_REGION WEB_SUBNET
  NET_MAC NET_IPV4_CIDR NET_IPV4_ADDR NET_IPV4_GATEWAY NET_IPV4_DNS
  NET_IPV6_ADDR NET_IPV6_1 NET_IPV6_2 NET_IPV6_3 NET_IPV6_4 NET_IPV6_GATEWAY NET_IPV6_DNS
)

# Directories that may contain baked, tokenized files.
SEARCH_DIRS=(/etc /usr/lib /usr/libexec)

# Substitute tokens in every file that contains a "@@" marker.
mapfile -d '' -t FILES < <(grep -rlZ '@@' "${SEARCH_DIRS[@]}" 2>/dev/null || true)
for f in "${FILES[@]}"; do
  for t in "${TOKENS[@]}"; do
    sed -i "s|@@${t}@@|${!t}|g" "$f"
  done
done

# sshd reads /etc/ssh/authorized_keys.d/%u, so the key file must be named after
# the login. It ships as ".../appuser"; rename it to $APP_USER.
KEYDIR=/etc/ssh/authorized_keys.d
if [ -f "${KEYDIR}/appuser" ] && [ "${APP_USER}" != "appuser" ]; then
  mv "${KEYDIR}/appuser" "${KEYDIR}/${APP_USER}"
fi

# Guard: no placeholder may survive into the image.
if grep -rl '@@' "${SEARCH_DIRS[@]}" 2>/dev/null; then
  echo "00-config: ERROR — unsubstituted @@TOKEN@@ placeholders remain (above)." >&2
  exit 1
fi

echo "00-config: customizations applied for APP_USER=${APP_USER}."
