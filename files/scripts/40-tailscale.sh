#!/usr/bin/env bash
#
# 40-tailscale.sh — finalize the rootful Tailscale exit node wiring.
#
# Tailscale is the SINGLE documented rootful exception in this stack: an exit
# node must program the host routing/NAT (real NET_ADMIN + host netns), which a
# rootless container can't do. Everything else stays rootless under the app user.
#
# Most of the moving parts are baked files handled by other phases:
#   - files/services/etc/containers/systemd/tailscale.container  (rootful quadlet)
#   - files/services/usr/lib/systemd/system/tailscale-authkey.path (trigger)
#   - files/services/etc/systemd/user/tailscale-authkey-init.service (+ symlink)
#   - files/services/usr/libexec/tailscale-authkey-init.sh        (key minter)
#   - files/services/etc/headscale/policy.json                    (auto-approve)
#   - files/services/usr/lib/tmpfiles.d/tailscale.conf            (bootstrap dir)
#   - files/base/usr/lib/sysctl.d/90-ip-forward.conf              (forwarding)
#   - files/scripts/30-firewall.sh                                (41641/udp)
#
# This phase only does the two things that must happen at build time here:
#   1. make the bootstrap helper executable, and
#   2. enable the rootful .path unit that starts the node once the app-user
#      bootstrap has minted and written the auth key.

set -xeuo pipefail

# cp preserves source perms, but be robust about the exec bit.
chmod 0755 /usr/libexec/tailscale-authkey-init.sh

# Enable the rootful trigger. tailscale.service (generated from the quadlet) has
# NO [Install] on purpose: it must not start before /var/lib/tailscale-bootstrap/
# authkey.env exists. tailscale-authkey.path watches for that file and starts it.
systemctl enable tailscale-authkey.path

echo "40-tailscale: exit-node wiring enabled (path trigger armed)."
