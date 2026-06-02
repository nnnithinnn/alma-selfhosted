#!/usr/bin/env bash
#
# 25-network.sh — enforce permissions on the baked NetworkManager static-IP
# profile. NetworkManager refuses to load keyfile connections whose mode is
# more permissive than 0600 (they may hold secrets), so `cp -a` preserving an
# arbitrary repo mode isn't safe — set it explicitly.

set -xeuo pipefail

NM_CONN=/etc/NetworkManager/system-connections/vps-static.nmconnection

chown root:root "${NM_CONN}"
chmod 0600 "${NM_CONN}"
