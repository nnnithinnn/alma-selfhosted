#!/usr/bin/env bash
#
# 20-users.sh — lock root and prepare rootless Podman (subuid/subgid). The
# app user itself is declared via systemd-sysusers, and SSH keys, sudo, sshd
# hardening and home/linger materialization ship declaratively under
# files/base (see /usr/lib/sysusers.d/app-user.conf,
# /etc/ssh/authorized_keys.d/<user>, /etc/sudoers.d/10-appuser,
# /etc/ssh/sshd_config.d/00-hardening.conf, /usr/lib/tmpfiles.d/app-user.conf).
#
# $APP_USER is exported by build.sh (from config.env); 00-config.sh has already
# substituted the @@APP_USER@@ tokens and renamed the authorized-keys file to
# match the login name.

set -xeuo pipefail

: "${APP_USER:?APP_USER must be set (sourced from config.env by build.sh)}"

# Lock the root account: no password login anywhere, no SSH as root.
passwd -l root

# Deterministic subuid/subgid ranges for rootless Podman user namespaces.
# (sysusers does not manage these, so set them explicitly.)
grep -q "^${APP_USER}:" /etc/subuid || echo "${APP_USER}:100000:65536" >> /etc/subuid
grep -q "^${APP_USER}:" /etc/subgid || echo "${APP_USER}:100000:65536" >> /etc/subgid

# sshd StrictModes refuses keys whose file or parent dir is group/world-writable,
# so normalize ownership + perms (cp preserves the build-context's looser modes).
chown root:root /etc/ssh/authorized_keys.d "/etc/ssh/authorized_keys.d/${APP_USER}"
chmod 0755 /etc/ssh/authorized_keys.d
chmod 0644 "/etc/ssh/authorized_keys.d/${APP_USER}"

# sudo/visudo reject any sudoers.d file that is not 0440 and root-owned.
chown root:root /etc/sudoers.d/10-appuser
chmod 0440 /etc/sudoers.d/10-appuser

# Fail the build now if the sudoers syntax/perms are wrong, rather than at runtime.
visudo -cf /etc/sudoers.d/10-appuser
