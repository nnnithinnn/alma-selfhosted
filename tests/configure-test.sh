#!/usr/bin/env bash
# tests/configure-test.sh
#
# Runs inside the built container image during CI (and locally via just update-golden).
# Tests the selfhosted-configure script end-to-end:
#
#   1. Runs /usr/lib/selfhosted/configure with the test config.env mounted at
#      /etc/selfhosted/config.env (all 13 output files are written).
#   2. Diffs every rendered file against the committed golden files in /golden
#      (bind-mounted from tests/golden/ by the caller).
#   3. Greps every rendered file for leftover @@TOKEN@@ strings.
#
# Exits 0 only if all checks pass.
#
# Called by CI (.github/workflows/build.yml test-image job) and by
# `just update-golden` (collect mode: skips the diff, just copies outputs).
#
# Environment:
#   GOLDEN_DIR  path to the golden files tree   (default: /golden)
#   COLLECT     if set to "1", copy rendered files to GOLDEN_DIR instead of diffing

set -euo pipefail

GOLDEN_DIR="${GOLDEN_DIR:-/golden}"
COLLECT="${COLLECT:-0}"
CONFIG_SRC="${CONFIG_SRC:-}"   # if set, copy this file to /etc/selfhosted/config.env
FAIL=0

# ---------------------------------------------------------------------------
# Set up config.env
# configure does `chown root:1000 /etc/selfhosted/config.env`, which fails on a
# read-only bind mount. Callers mount the test config at a tmp path and set
# CONFIG_SRC so we can copy it to a writable location before configure runs.
# ---------------------------------------------------------------------------
if [[ -n "$CONFIG_SRC" ]]; then
    mkdir -p /etc/selfhosted
    cp "$CONFIG_SRC" /etc/selfhosted/config.env
fi

# ---------------------------------------------------------------------------
# Output paths: (rendered-destination, golden-relative-path) pairs
# ---------------------------------------------------------------------------
declare -a RENDERED=(
    /etc/caddy/Caddyfile
    /etc/headscale/config.yaml
    /etc/headscale/policy.json
    /etc/containers/systemd/tailscale.container
    /etc/containers/systemd/users/1000/nextcloud.container
    /etc/containers/systemd/users/1000/collabora.container
    /etc/containers/systemd/users/1000/web.network
    /etc/sysusers.d/app-user.conf
    /etc/tmpfiles.d/app-user.conf
    /etc/tmpfiles.d/tailscale.conf
    /etc/sudoers.d/10-appuser
    /etc/NetworkManager/system-connections/vps-static.nmconnection
    /etc/ssh/authorized_keys.d/testuser
)
# Golden paths mirror /etc/... with the /etc/ prefix stripped.
declare -a GOLDEN=(
    caddy/Caddyfile
    headscale/config.yaml
    headscale/policy.json
    containers/systemd/tailscale.container
    containers/systemd/users/1000/nextcloud.container
    containers/systemd/users/1000/collabora.container
    containers/systemd/users/1000/web.network
    sysusers.d/app-user.conf
    tmpfiles.d/app-user.conf
    tmpfiles.d/tailscale.conf
    sudoers.d/10-appuser
    network-connections/vps-static.nmconnection
    ssh/authorized_keys.d/testuser
)

# ---------------------------------------------------------------------------
# Step 1: run configure
# ---------------------------------------------------------------------------
echo "=== running configure ==="
/usr/lib/selfhosted/configure

echo ""
echo "=== configure completed ==="
echo ""

# ---------------------------------------------------------------------------
# Step 2a: collect mode — copy rendered files into GOLDEN_DIR
# ---------------------------------------------------------------------------
if [[ "$COLLECT" == "1" ]]; then
    echo "=== collecting golden files into $GOLDEN_DIR ==="
    for i in "${!RENDERED[@]}"; do
        dest="${RENDERED[$i]}"
        golden="$GOLDEN_DIR/${GOLDEN[$i]}"
        mkdir -p "$(dirname "$golden")"
        cp "$dest" "$golden"
        echo "  collected: ${GOLDEN[$i]}"
    done
    echo ""
    echo "Golden files collected."
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 2b: diff mode — compare rendered files against golden files
# ---------------------------------------------------------------------------
echo "=== diffing rendered files against golden files ==="
for i in "${!RENDERED[@]}"; do
    dest="${RENDERED[$i]}"
    golden="$GOLDEN_DIR/${GOLDEN[$i]}"

    if [[ ! -f "$dest" ]]; then
        echo "FAIL: rendered file missing: $dest"
        FAIL=1
        continue
    fi

    if [[ ! -f "$golden" ]]; then
        echo "FAIL: golden file missing: $golden"
        echo "      run 'just update-golden' to generate it"
        FAIL=1
        continue
    fi

    if diff -u "$golden" "$dest"; then
        echo "OK: ${GOLDEN[$i]}"
    else
        echo "FAIL: ${dest} differs from golden ${GOLDEN[$i]}"
        FAIL=1
    fi
    echo ""
done

# ---------------------------------------------------------------------------
# Step 3: check for unreplaced @@TOKEN@@ strings (excluding comment lines)
# ---------------------------------------------------------------------------
echo "=== checking for unreplaced @@ tokens ==="
for i in "${!RENDERED[@]}"; do
    dest="${RENDERED[$i]}"
    [[ -f "$dest" ]] || continue
    # Strip comment lines (# and //) before checking — some templates have
    # @@TOKEN@@ in doc comments to illustrate the syntax; those are expected.
    if grep -vE '^\s*(#|//)' "$dest" | grep -qP '@@[A-Z_]+@@' 2>/dev/null; then
        echo "FAIL: unreplaced tokens in $dest (non-comment lines):"
        grep -vE '^\s*(#|//)' "$dest" | grep -nP '@@[A-Z_]+@@' | sed 's/^/  /'
        FAIL=1
    else
        echo "OK (no tokens): ${GOLDEN[$i]}"
    fi
done

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All configure tests passed."
else
    echo "FAILED: one or more configure tests failed (see above)."
fi
exit "$FAIL"
