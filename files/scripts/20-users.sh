#!/usr/bin/env bash
#
# 20-users.sh — lock root and create the /etc/ssh/authorized_keys.d directory.
#
# The app user itself (UID 1000) is declared at runtime by sysusers.d via a
# template written by selfhosted-configure.service. SSH keys, sudo, and linger
# are all handled at runtime too — nothing personal is baked into the image.
#
# We keep a minimal UID-keyed subuid/subgid entry here so that the subuid range
# for UID 1000 is baked at build time as a fallback; selfhosted-configure.service
# also ensures the entry exists at runtime in case /etc/subuid is reset.

set -xeuo pipefail

# Lock the root account: no password login anywhere, no SSH as root.
passwd -l root

# Bake a UID-keyed subuid/subgid so UID 1000 (the app user, whatever its name)
# always has a deterministic rootless Podman namespace range. Username-keyed
# entries would require knowing APP_USER at build time; UID-keyed works regardless.
grep -q "^1000:" /etc/subuid || echo "1000:100000:65536" >> /etc/subuid
grep -q "^1000:" /etc/subgid || echo "1000:100000:65536" >> /etc/subgid

# Create the authorized_keys.d directory with the perms sshd StrictModes requires.
# The actual key file is written at runtime by selfhosted-configure from SSH_PUBKEY.
mkdir -p /etc/ssh/authorized_keys.d
chown root:root /etc/ssh/authorized_keys.d
chmod 0755 /etc/ssh/authorized_keys.d
