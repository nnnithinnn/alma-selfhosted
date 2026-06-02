#!/usr/bin/env bash

set -xeuo pipefail

# SELinux file contexts ######################################################
#
# Rootless containers run as `container_t` and can only read host files
# labeled `container_file_t`. The baked Caddyfile lives in /etc (default
# label `etc_t`), so the rootless Caddy container can't read it.
#
# We can't use podman's `:Z` relabel option: that calls lsetxattr() at runtime
# and an unprivileged rootless user cannot relabel a root-owned file
# (=> "operation not permitted", container exits 126).
#
# Instead we teach the SELinux policy to label /etc/caddy as container_file_t.
# bootc relabels the tree at deploy time using file_contexts (libselinux also
# reads file_contexts.local), so the file lands as container_file_t on the
# target and the quadlet can mount it read-only WITHOUT `:Z`.
#
# Note: on a non-SELinux build host (Ubuntu CI/dev) the restorecon below is a
# no-op because security.selinux xattrs aren't supported there. The label is
# applied by bootc at install/deploy time regardless; the fcontext rule is the
# part that matters.

FCONTEXT_LOCAL=/etc/selinux/targeted/contexts/files/file_contexts.local

echo '/etc/caddy(/.*)?    system_u:object_r:container_file_t:s0' >> "${FCONTEXT_LOCAL}"
echo '/etc/headscale(/.*)?    system_u:object_r:container_file_t:s0' >> "${FCONTEXT_LOCAL}"
echo '/etc/nextcloud(/.*)?    system_u:object_r:container_file_t:s0' >> "${FCONTEXT_LOCAL}"

# Best-effort relabel for SELinux-enabled build hosts; ignore failure elsewhere.
restorecon -RFv /etc/caddy || true
restorecon -RFv /etc/headscale || true
restorecon -RFv /etc/nextcloud || true
