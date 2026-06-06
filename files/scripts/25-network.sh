#!/usr/bin/env bash
#
# 25-network.sh — placeholder; static networking is now configured at runtime.
#
# The vps-static.nmconnection file is no longer baked into the image. Instead,
# selfhosted-configure.service writes it from a template at boot time with the
# correct 0600 permissions (required by NetworkManager for keyfiles).
#
# This script is retained as an explicit no-op so the numbered build sequence
# is unchanged and the intent is documented.

set -xeuo pipefail

: "Static networking is configured at runtime by selfhosted-configure.service."
