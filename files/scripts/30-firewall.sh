#!/usr/bin/env bash
#
# 30-firewall.sh — install and pre-configure firewalld with a minimal,
# default-drop inbound policy. Only the ports actually needed by the services
# running on this host are opened; everything else inbound is rejected.
#
# firewalld (rather than a hand-written nftables ruleset) is used because
# podman/netavark and tailscale integrate with it automatically (zones,
# forward/masquerade), which matters once the rootful Tailscale exit node is
# added later.

set -xeuo pipefail

# firewalld pulls its python backend + nftables (already present). dnf has
# network/repo access during the image build.
dnf install -y firewalld

# Replace firewalld's nftables backend coexistence: keep nftables.service off
# (firewalld owns the nft ruleset); enable firewalld at boot.
systemctl disable nftables.service 2>/dev/null || true
systemctl enable firewalld.service

# Configure the *permanent* ruleset offline (no running daemon needed).
#
# firewall-offline-cmd returns benign non-zero exit codes for already-applied
# state (ALREADY_ENABLED=11, NOT_ENABLED=12, ZONE_ALREADY_SET=16). Those would
# abort the build under `set -e`, so wrap each idempotent change to swallow only
# those codes.
fw() {
	local rc=0
	firewall-offline-cmd "$@" || rc=$?
	# 0=ok; 11/12/16 are benign idempotent-state codes.
	case "$rc" in
		0 | 11 | 12 | 16) return 0 ;;
		*) return "$rc" ;;
	esac
}

# Default zone `public` already allows ssh + dhcpv6-client, and permits ICMP
# (incl. echo/ping) by default. We add the web front door.
fw --set-default-zone=public

# Explicit ssh (idempotent; guards against base-image default changes).
fw --zone=public --add-service=ssh

# Caddy front door: HTTP-01 ACME challenge + redirect, and HTTPS.
fw --zone=public --add-service=http
fw --zone=public --add-service=https

# Drop the distro default `cockpit` service (port 9090) — cockpit is debloated
# and never runs on this host, so the open port serves no purpose.
fw --zone=public --remove-service-from-zone=cockpit

# Headscale embedded DERP STUN (NAT traversal). DERP relay traffic itself rides
# HTTPS through Caddy (443); only the STUN listener needs a direct UDP path.
fw --zone=public --add-port=3478/udp

# Tailscale direct connections (exit node). The rootful Tailscale container uses
# host networking and binds this port directly on the host for peer-to-peer
# WireGuard; opening it lets clients establish direct (non-DERP-relayed) paths to
# the exit node. See files/services/etc/containers/systemd/tailscale.container.
fw --zone=public --add-port=41641/udp
# Show the resulting permanent config in the build log for verification.
firewall-offline-cmd --zone=public --list-all
