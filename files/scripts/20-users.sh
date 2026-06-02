#!/usr/bin/env bash
#
# 20-users.sh — lock root and prepare rootless Podman (subuid/subgid). The
# `nithin` user itself is declared via systemd-sysusers, and SSH keys, sudo,
# sshd hardening and home/linger materialization ship declaratively under
# files/system (see /usr/lib/sysusers.d/nithin.conf,
# /etc/ssh/authorized_keys.d/nithin, /etc/sudoers.d/10-nithin,
# /etc/ssh/sshd_config.d/00-hardening.conf, /usr/lib/tmpfiles.d/nithin.conf).

set -xeuo pipefail

# Lock the root account: no password login anywhere, no SSH as root.
passwd -l root

# Deterministic subuid/subgid ranges for rootless Podman user namespaces.
# (sysusers does not manage these, so set them explicitly.)
grep -q '^nithin:' /etc/subuid || echo 'nithin:100000:65536' >> /etc/subuid
grep -q '^nithin:' /etc/subgid || echo 'nithin:100000:65536' >> /etc/subgid

# sshd StrictModes refuses keys whose file or parent dir is group/world-writable,
# so normalize ownership + perms (cp preserves the build-context's looser modes).
chown root:root /etc/ssh/authorized_keys.d /etc/ssh/authorized_keys.d/nithin
chmod 0755 /etc/ssh/authorized_keys.d
chmod 0644 /etc/ssh/authorized_keys.d/nithin

# sudo/visudo reject any sudoers.d file that is not 0440 and root-owned.
chown root:root /etc/sudoers.d/10-nithin
chmod 0440 /etc/sudoers.d/10-nithin

# Fail the build now if the sudoers syntax/perms are wrong, rather than at runtime.
visudo -cf /etc/sudoers.d/10-nithin
