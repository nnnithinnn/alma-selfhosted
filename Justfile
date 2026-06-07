# alma-selfhosted — local build & test tasks.
#
# Build the bootc container image with Podman, turn it into a test or production
# installer ISO with bootc-image-builder, and boot/test it in QEMU.
#
# Hybrid privilege model — the QEMU boot/test loop is rootless; only the image
# build and ISO step need sudo:
#
#   * `build` + `_bib` + the `podman` prune in `clean` run rootful. They share
#     the rootful container store (/var/lib/containers/storage). This is NOT a
#     choice: bootc-image-builder's experimental rootless `--in-vm` mode relabels
#     its osbuild store with `chcon` (a security.selinux xattr), which only works
#     on a host with SELinux. This box (Debian) has no SELinux, so rootless BIB
#     fails with "chcon ... Operation not permitted". Rootful BIB is the only
#     working path here.
#   * Everything else is rootless. `_bib` uses BIB's `--chown $(id):$(id)` so the
#     installer ISO and artifacts are owned by you, and QEMU runs unprivileged —
#     so `run-iso`, `run-disk`, `ssh`, and `stop` need no sudo. That requires KVM
#     access: add yourself to the `kvm` group once with
#     `sudo usermod -aG kvm $USER`, then re-login.
#
# All ephemeral VM artifacts (writable OVMF vars, the 2 TB Nextcloud data disk,
# the serial console log) live under ./output/vm so nothing outside the current
# directory is touched — the only exception is reading/copying the OVMF firmware
# from /usr/share/OVMF. `just stop` and `just clean` remove the scratch dir.

# --- Configuration ----------------------------------------------------------

image        := "localhost/alma-selfhosted"
containerfile := "Containerfile"
variant      := ""
iso_config   := "iso.toml"

# Login name baked into the image (read from config.env's APP_USER if present),
# used by the `ssh` recipe to log into the test VM. Falls back to "app" when
# config.env doesn't exist (e.g. CI, or before running `just config`).
app_user     := `[ -f config.env ] && grep -m1 "^APP_USER=" config.env | sed "s/^APP_USER=//; s/^['\"]//; s/['\"]$//" || echo app`

# Remote image the INSTALLED system should track for `bootc upgrade`. Empty for
# local testing (the box just boots the locally built image, no remote switch).
# Set it to build production install media; the `prod-iso` recipe wires this up
# to the private GHCR image so the VPS pulls upgrades from there.
update_ref    := ""
update_signed := "false"

# Pull credentials for a PRIVATE registry. Path to a local, gitignored
# containers-auth JSON; when present, `_bib` bakes it into the installed
# system's /etc/ostree/auth.json so `bootc upgrade` can pull the private image.
# Never committed, never part of the published container image. Create it with:
#   podman login --authfile ghcr-auth.json ghcr.io     # username + a read:packages PAT
registry_auth := "ghcr-auth.json"

# The private image the production install media tracks for upgrades.
prod_ref      := "ghcr.io/nnnithinnn/alma-selfhosted:latest"

# bootc-image-builder. Override with
#   just bib_image=ghcr.io/osbuild/bootc-image-builder:latest test-iso
# if quay.io is unreachable.
bib_image    := "quay.io/centos-bootc/bootc-image-builder:latest"

# Build outputs (all inside CWD; ./output is gitignored).
output       := "output"
vm_dir       := "output/vm"
iso_file     := "output/bootiso/install.iso"
raw_disk     := "output/disk.raw"

# Host OVMF firmware (read-only code + a vars template we copy per VM).
ovmf_code     := "/usr/share/OVMF/OVMF_CODE_4M.fd"
ovmf_vars_src := "/usr/share/OVMF/OVMF_VARS_4M.fd"

# Address QEMU's VNC server binds to for the installer/disk consoles. Default is
# all interfaces so you can point a VNC client straight at this host (no SSH
# tunnel needed): `remote-viewer vnc://<this-host>:5900`. Override to restrict,
# e.g. `just vnc_bind=127.0.0.1 run-iso` (loopback, needs an SSH -L tunnel).
vnc_bind     := "0.0.0.0"

# --- Help -------------------------------------------------------------------

# Show all available recipes (default).
default:
    @just --list

# --- Configuration ----------------------------------------------------------

# Interactive wizard: creates/updates config.env and optionally ghcr-auth.json.
# Re-runnable: existing values are shown as defaults; press Enter to keep them.
# Run this before `just prod-iso`.
config:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG=config.env
    TEMPLATE=config.env.template

    # ---- Load current values (from config.env if it exists, else template) ----
    # Template provides defaults; config.env overrides them.
    # Uses printf -v to avoid shell interpretation of values containing $ or spaces
    # (e.g. APP_PASSWORD_HASH=$6$..., SSH_PUBKEY=ssh-ed25519 AAAA...).
    _src() {
        local f="$1" overwrite="${2:-0}"
        local line var val
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*) ]]; then
                var="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
                # Strip surrounding single quotes: 'value' → value
                if [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
                    val="${val:1:${#val}-2}"
                # Strip surrounding double quotes: "value" → value
                elif [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
                    val="${val:1:${#val}-2}"
                fi
                # Template (overwrite=0): only set if not already set.
                # Config.env (overwrite=1): always set (config wins over template).
                if [[ "$overwrite" == "1" ]] || [[ ! -v "$var" ]]; then
                    printf -v "$var" '%s' "$val"
                    export "$var"
                fi
            fi
        done < "$f"
    }
    [ -f "$TEMPLATE" ] && _src "$TEMPLATE" 0
    [ -f "$CONFIG" ]   && _src "$CONFIG"   1

    # ---- Helper: prompt with current value as default -------------------------
    ask() {
        local var="$1" prompt="$2"
        local cur="${!var:-}"
        local display="${cur:-(empty)}"
        local input
        read -rp "  $prompt [$display]: " input || true
        printf '%s' "${input:-$cur}"
    }

    ask_required() {
        local var="$1" prompt="$2"
        local val
        while true; do
            val="$(ask "$var" "$prompt")"
            if [[ -n "$val" ]]; then
                printf '%s' "$val"
                return
            fi
            echo "  (required — cannot be empty)" >&2
        done
    }

    echo ""
    echo "alma-selfhosted — deployment configuration wizard"
    echo "=================================================="
    echo "Press Enter to keep the current/default value shown in [brackets]."
    echo ""

    # ---- Identity -------------------------------------------------------------
    echo "--- Identity ---"
    APP_USER="$(ask_required APP_USER "OS login name for the admin user (UID 1000)")"
    NEXTCLOUD_ADMIN_USER="$(ask_required NEXTCLOUD_ADMIN_USER "Nextcloud admin account username")"
    echo ""

    # ---- Domains --------------------------------------------------------------
    echo "--- Domains ---"
    DOMAIN="$(ask_required DOMAIN "Base domain (e.g. example.com)")"
    HEADSCALE_HOST="$(ask_required HEADSCALE_HOST "Headscale hostname (e.g. vpn.example.com)")"
    NEXTCLOUD_HOST="$(ask_required NEXTCLOUD_HOST "Nextcloud hostname (e.g. cloud.example.com)")"
    MAGICDNS_BASE_DOMAIN="$(ask_required MAGICDNS_BASE_DOMAIN "MagicDNS base domain (must differ from HEADSCALE_HOST domain)")"
    ACME_EMAIL="$(ask_required ACME_EMAIL "ACME / Let's Encrypt email")"
    echo ""

    # ---- Nextcloud ------------------------------------------------------------
    echo "--- Nextcloud ---"
    NEXTCLOUD_PHONE_REGION="$(ask_required NEXTCLOUD_PHONE_REGION "Phone region ISO code (e.g. US, GB, IN)")"
    WEB_SUBNET="$(ask_required WEB_SUBNET "Internal web container subnet (e.g. 10.10.10.0/24)")"
    echo ""

    # ---- Static networking (optional) -----------------------------------------
    echo "--- Static networking (optional — leave blank for DHCP) ---"
    _static_cur=""
    [[ -n "${NET_MAC:-}" ]] && _static_cur="y"
    read -rp "  Configure static IP? [${_static_cur:-N}]: " _static_ans || true
    _static_ans="${_static_ans:-${_static_cur:-N}}"
    if [[ "${_static_ans,,}" == "y" ]]; then
        NET_MAC="$(ask_required NET_MAC "NIC MAC address (e.g. 52:54:00:ab:cd:ef)")"
        NET_IPV4_CIDR="$(ask NET_IPV4_CIDR "IPv4 CIDR (e.g. 192.0.2.10/24)")"
        NET_IPV4_ADDR="$(ask NET_IPV4_ADDR "IPv4 address (plain, e.g. 192.0.2.10)")"
        NET_IPV4_GATEWAY="$(ask NET_IPV4_GATEWAY "IPv4 gateway")"
        NET_IPV4_DNS="$(ask NET_IPV4_DNS "IPv4 DNS (semicolon-separated, e.g. 1.1.1.1;9.9.9.9;)")"
        NET_IPV6_ADDR="$(ask NET_IPV6_ADDR "IPv6 address (CIDR)")"
        NET_IPV6_1="$(ask NET_IPV6_1 "IPv6 addr 1 (CIDR)")"
        NET_IPV6_2="$(ask NET_IPV6_2 "IPv6 addr 2 (CIDR, optional)")"
        NET_IPV6_3="$(ask NET_IPV6_3 "IPv6 addr 3 (CIDR, optional)")"
        NET_IPV6_4="$(ask NET_IPV6_4 "IPv6 addr 4 (CIDR, optional)")"
        NET_IPV6_GATEWAY="$(ask NET_IPV6_GATEWAY "IPv6 gateway")"
        NET_IPV6_DNS="$(ask NET_IPV6_DNS "IPv6 DNS (semicolon-separated)")"
    else
        NET_MAC="" NET_IPV4_CIDR="" NET_IPV4_ADDR="" NET_IPV4_GATEWAY="" NET_IPV4_DNS=""
        NET_IPV6_ADDR="" NET_IPV6_1="" NET_IPV6_2="" NET_IPV6_3="" NET_IPV6_4=""
        NET_IPV6_GATEWAY="" NET_IPV6_DNS=""
    fi
    echo ""

    # ---- SSH public key -------------------------------------------------------
    echo "--- SSH key ---"
    if [[ -n "${SSH_PUBKEY:-}" ]]; then
        echo "  Current key: ${SSH_PUBKEY:0:60}..."
        read -rp "  Path to new key file (Enter to keep current): " _keypath || true
    else
        read -rp "  Path to SSH public key file (e.g. ~/.ssh/id_ed25519.pub): " _keypath || true
    fi
    if [[ -n "${_keypath:-}" ]]; then
        _keypath="${_keypath/#\~/$HOME}"
        if [[ ! -f "$_keypath" ]]; then
            echo "  ERROR: '$_keypath' not found." >&2
            exit 1
        fi
        SSH_PUBKEY="$(cat "$_keypath")"
        echo "  Key loaded from $_keypath."
    fi
    if [[ -z "${SSH_PUBKEY:-}" ]]; then
        echo "  ERROR: SSH_PUBKEY is required." >&2
        exit 1
    fi
    echo ""

    # ---- Password -------------------------------------------------------------
    echo "--- Password for $APP_USER ---"
    if [[ -n "${APP_PASSWORD_HASH:-}" ]]; then
        read -rp "  Change password? [y/N]: " _chpw || true
        _chpw="${_chpw:-N}"
    else
        _chpw="y"
    fi
    if [[ "${_chpw,,}" == "y" ]]; then
        while true; do
            read -rsp "  New password: " _pw1; echo ""
            read -rsp "  Confirm password: " _pw2; echo ""
            if [[ "$_pw1" == "$_pw2" && -n "$_pw1" ]]; then
                APP_PASSWORD_HASH="$(openssl passwd -6 "$_pw1")"
                echo "  Password hashed (SHA-512)."
                break
            fi
            echo "  Passwords do not match or are empty — try again." >&2
        done
    fi
    if [[ -z "${APP_PASSWORD_HASH:-}" ]]; then
        echo "  ERROR: APP_PASSWORD_HASH is required." >&2
        exit 1
    fi
    echo ""

    # ---- GHCR auth (optional) -------------------------------------------------
    echo "--- GHCR pull credentials (optional) ---"
    echo "  Needed for \`bootc upgrade\` from the private GHCR image."
    echo "  Skip if you will run \`podman login --authfile ghcr-auth.json ghcr.io\` separately."
    read -rp "  GitHub PAT with read:packages scope (Enter to skip): " _ghpat || true
    if [[ -n "${_ghpat:-}" ]]; then
        read -rp "  GitHub username: " _ghuser || true
        if [[ -n "${_ghuser:-}" ]]; then
            _b64="$(printf '%s:%s' "$_ghuser" "$_ghpat" | base64 -w0)"
            printf '{\n  "auths": {\n    "ghcr.io": {\n      "auth": "%s"\n    }\n  }\n}\n' \
                "$_b64" > ghcr-auth.json
            chmod 600 ghcr-auth.json
            echo "  ghcr-auth.json written."
        fi
    else
        echo "  Skipped — ghcr-auth.json unchanged."
    fi
    echo ""

    # ---- Write config.env (atomic) --------------------------------------------
    _tmp="$(mktemp config.env.XXXXXX)"
    {
        printf '%s\n' "# alma-selfhosted deployment configuration — generated by \`just config\`"
        printf '%s\n' "# DO NOT COMMIT — this file is gitignored. Edit via \`just config\` or directly."
        printf '%s\n' ""
        printf '%s\n' "# Identity"
        printf "APP_USER='%s'\n"             "$APP_USER"
        printf "NEXTCLOUD_ADMIN_USER='%s'\n" "$NEXTCLOUD_ADMIN_USER"
        printf '%s\n' ""
        printf '%s\n' "# Domains"
        printf "DOMAIN='%s'\n"              "$DOMAIN"
        printf "HEADSCALE_HOST='%s'\n"      "$HEADSCALE_HOST"
        printf "NEXTCLOUD_HOST='%s'\n"      "$NEXTCLOUD_HOST"
        printf "MAGICDNS_BASE_DOMAIN='%s'\n" "$MAGICDNS_BASE_DOMAIN"
        printf "ACME_EMAIL='%s'\n"          "$ACME_EMAIL"
        printf '%s\n' ""
        printf '%s\n' "# Nextcloud"
        printf "NEXTCLOUD_PHONE_REGION='%s'\n" "$NEXTCLOUD_PHONE_REGION"
        printf "WEB_SUBNET='%s'\n"          "$WEB_SUBNET"
        printf '%s\n' ""
        printf '%s\n' "# Static networking (blank = DHCP)"
        printf "NET_MAC='%s'\n"             "$NET_MAC"
        printf "NET_IPV4_CIDR='%s'\n"       "$NET_IPV4_CIDR"
        printf "NET_IPV4_ADDR='%s'\n"       "$NET_IPV4_ADDR"
        printf "NET_IPV4_GATEWAY='%s'\n"    "$NET_IPV4_GATEWAY"
        printf "NET_IPV4_DNS='%s'\n"        "$NET_IPV4_DNS"
        printf "NET_IPV6_ADDR='%s'\n"       "$NET_IPV6_ADDR"
        printf "NET_IPV6_1='%s'\n"          "$NET_IPV6_1"
        printf "NET_IPV6_2='%s'\n"          "$NET_IPV6_2"
        printf "NET_IPV6_3='%s'\n"          "$NET_IPV6_3"
        printf "NET_IPV6_4='%s'\n"          "$NET_IPV6_4"
        printf "NET_IPV6_GATEWAY='%s'\n"    "$NET_IPV6_GATEWAY"
        printf "NET_IPV6_DNS='%s'\n"        "$NET_IPV6_DNS"
        printf '%s\n' ""
        printf '%s\n' "# SSH public key"
        printf "SSH_PUBKEY='%s'\n"          "$SSH_PUBKEY"
        printf '%s\n' ""
        printf '%s\n' "# SHA-512 password hash (generate with: openssl passwd -6)"
        printf "APP_PASSWORD_HASH='%s'\n"   "$APP_PASSWORD_HASH"
    } > "$_tmp"
    mv "$_tmp" "$CONFIG"
    chmod 600 "$CONFIG"
    echo "config.env written (chmod 600)."
    echo ""
    echo "Next steps:"
    echo "  just build      # build the bootc image"
    echo "  just prod-iso   # build production installer ISO"

# --- Build ------------------------------------------------------------------

# Uses the layer cache; run `just clean` first to force a fully fresh build.

# Build the bootc container image with Podman (rootful: lands in the shared
# /var/lib/containers/storage store that the rootful _bib reads).
build:
    sudo podman build \
        --network=host \
        --security-opt=label=disable \
        --cap-add=all \
        --device /dev/fuse \
        --build-arg IMAGE_NAME={{image}} \
        --build-arg IMAGE_REGISTRY=localhost \
        --build-arg VARIANT={{variant}} \
        -t {{image}} \
        -f {{containerfile}} \
        .

# Run the built container image interactively for quick inspection (rootful,
# no QEMU). Useful to verify baked files without a full ISO build + VM cycle.
# Exits clean — no persistent state is written.
run-cnt:
    sudo podman run --rm -it --privileged \
        --security-opt=label=disable \
        --cap-add=all \
        {{image}} /bin/bash

# Regenerate tests/golden/ from the current image + tests/config.env.test.
# Run `just build` first, then commit the diff to tests/golden/ after this completes.
# Golden files are the expected output of `configure` for the committed test config;
# CI diffs every rendered file against them on every PR.
update-golden:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Regenerating tests/golden/ from image {{image}} ..."
    mkdir -p tests/golden
    sudo podman run --rm \
        -v "$(pwd)/tests/config.env.test:/tmp/config.env.test:ro" \
        -v "$(pwd)/tests/golden:/golden" \
        -v "$(pwd)/tests/configure-test.sh:/configure-test.sh:ro" \
        {{image}} \
        bash -c 'COLLECT=1 GOLDEN_DIR=/golden CONFIG_SRC=/tmp/config.env.test /bin/bash /configure-test.sh'
    # The container ran as root; hand ownership back to the current user.
    sudo chown -R "$(id -u):$(id -g)" tests/golden/
    echo ""
    echo "Golden files written to tests/golden/ — inspect the diff and commit."

# Remove all build outputs (./output, incl. VM scratch) and the Podman build cache.
clean:
    # Stop any running test VM first so it releases open files under ./output.
    # QEMU runs rootless (kvm group), so no sudo needed to kill it.
    pkill -f '[O]VMF_VARS_test.fd' || true
    sleep 1
    # ./output may hold root-owned osbuild artifacts from a rootful _bib run that
    # failed before its --chown, so remove it with sudo.
    sudo rm -rf ./{{output}}
    # Drop the locally built image plus any dangling layers and build cache, so
    # the next build is fully fresh (avoids the stale-layer trap where newly
    # added files are not picked up). The digest-pinned base and the
    # bootc-image-builder image are kept (immutable, expensive to re-pull).
    # Rootful, because the image lives in the rootful store shared with _bib.
    sudo podman rmi -f {{image}} 2>/dev/null || true
    sudo podman image prune -f
    sudo podman builder prune -f
    # Clear the stale SSH host key for the test VM.
    ssh-keygen -R '[127.0.0.1]:2222' >/dev/null 2>&1 || true

# Internal: build an installer ISO with bootc-image-builder from iso.toml.
_bib:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo rm -rf ./{{output}}
    mkdir -p ./{{output}}
    cp {{iso_config}} ./{{output}}/config.toml
    CFG=./{{output}}/config.toml
    if [ -n "{{update_ref}}" ]; then
        # Production media: switch the installed box to the remote image so
        # `bootc upgrade` tracks it. Fill the same tokens CI substitutes.
        SIG=""
        if [ "{{update_signed}}" = "true" ]; then SIG="--enforce-container-sigpolicy"; fi
        sed -i "s#<IMAGE_SIGNED>#${SIG}#; s#<UPDATE_IMAGE_REF>#{{update_ref}}#" "$CFG"
        echo "Production install media tracking {{update_ref}} (signed={{update_signed}})."
    else
        # Local testing only: don't switch to a remote image; boot the locally
        # built image as-is.
        sed -i '/bootc switch/d' "$CFG"
    fi
    # Inject deployment config (config.env) into the kickstart so the installed
    # system has /etc/selfhosted/config.env on first boot. When the gitignored
    # config.env exists, replace the placeholder with a %post that writes the
    # file verbatim. When absent (CI, generic test ISO), drop the placeholder
    # silently — selfhosted-configure exits 0 gracefully until config.env is
    # placed manually (e.g. via `just config` + rebuilding the ISO).
    if [ -f "config.env" ]; then
        {
            echo '%post --erroronfail --log=/root/anaconda-config.log'
            echo 'mkdir -p /etc/selfhosted'
            echo "cat > /etc/selfhosted/config.env <<'CONFIGEOF'"
            cat "config.env"
            echo 'CONFIGEOF'
            echo 'chmod 0644 /etc/selfhosted/config.env'
            echo '%end'
        } > ./{{output}}/config-post.ks
        sed -i -e '/# <SELFHOSTED_CONFIG_POST>/{r ./{{output}}/config-post.ks' -e 'd}' "$CFG"
        rm -f ./{{output}}/config-post.ks
        echo "Baked /etc/selfhosted/config.env from config.env into the kickstart."
    else
        sed -i '/# <SELFHOSTED_CONFIG_POST>/d' "$CFG"
        echo "No config.env found; building generic ISO (system boots unconfigured)."
    fi
    # Inject private-registry pull credentials for `bootc upgrade`. When the
    # gitignored auth file exists, replace the kickstart placeholder with a
    # %post that writes /etc/ostree/auth.json on the installed system. The token
    # rides only in the ISO + installed disk, never in the published image.
    if [ -f "{{registry_auth}}" ]; then
        {
            echo '%post --erroronfail --log=/root/anaconda-auth.log'
            echo 'mkdir -p /etc/ostree'
            echo "cat > /etc/ostree/auth.json <<'AUTHEOF'"
            cat "{{registry_auth}}"
            echo 'AUTHEOF'
            echo 'chmod 600 /etc/ostree/auth.json'
            echo '%end'
        } > ./{{output}}/auth-post.ks
        sed -i -e '/# <REGISTRY_AUTH_POST>/{r ./{{output}}/auth-post.ks' -e 'd}' "$CFG"
        rm -f ./{{output}}/auth-post.ks
        echo "Baked /etc/ostree/auth.json from {{registry_auth}} into the kickstart."
    else
        sed -i '/# <REGISTRY_AUTH_POST>/d' "$CFG"
        echo "No {{registry_auth}}; building without private-registry credentials."
    fi
    # Rootful build: bootc-image-builder needs real root here. Its experimental
    # rootless `--in-vm` mode relabels the osbuild store with chcon (a
    # security.selinux xattr) which only an SELinux-enabled host allows; this box
    # has no SELinux, so rootless fails with "chcon ... Operation not permitted".
    # `--chown $(id):$(id)` hands the output back to you, so the QEMU recipes that
    # consume it (run-iso/run-disk/stop) stay rootless.
    sudo podman run \
        --rm -it --privileged --pull=newer \
        --network=host \
        --security-opt label=type:unconfined_t \
        -v ./{{output}}:/output \
        -v ./{{output}}/config.toml:/config.toml:ro \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        {{bib_image}} \
        --chown $(id -u):$(id -g) \
        --type iso \
        --use-librepo=False \
        --progress verbose \
        {{image}}

# Build a TEST installer ISO (boots the locally built image, no remote switch or
# creds); validate it in QEMU with `just run-iso`.
test-iso: _bib

# Build PRODUCTION install media for the VPS: the installed system switches to
# the private GHCR image and bakes its pull creds, so `bootc upgrade` works.
# Requires {{registry_auth}} to exist (otherwise the box can't pull upgrades).
prod-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "config.env" ]; then
        echo "ERROR: config.env not found. Create it first:" >&2
        echo "  just config" >&2
        exit 1
    fi
    if [ ! -f "{{registry_auth}}" ]; then
        echo "ERROR: {{registry_auth}} not found. Create it first:" >&2
        echo "  podman login --authfile {{registry_auth}} ghcr.io" >&2
        exit 1
    fi
    just update_ref="{{prod_ref}}" update_signed="{{update_signed}}" registry_auth="{{registry_auth}}" test-iso

# --- VM scratch -------------------------------------------------------------

# Create a fresh, empty 2 TB Nextcloud data disk (WIPES the existing one).
data-disk:
    mkdir -p {{vm_dir}}
    qemu-img create -f qcow2 {{vm_dir}}/ncdata.qcow2 2T

# --- Run / test in QEMU -----------------------------------------------------

# Boots a fresh raw OS disk + the 2 TB data disk; exercises the iso.toml kickstart.

# Boot the installer ISO in QEMU (UEFI), viewable over VNC on 127.0.0.1:5900.
run-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{iso_file}}" ]; then
        echo "{{iso_file}} not found — building test ISO first..."
        just test-iso
    fi
    pkill -f '[O]VMF_VARS_test.fd' || true
    sleep 1
    mkdir -p {{vm_dir}}
    rm -f {{vm_dir}}/OVMF_VARS_test.fd {{raw_disk}}
    cp {{ovmf_vars_src}} {{vm_dir}}/OVMF_VARS_test.fd
    qemu-img create -f raw {{raw_disk}} 20G
    [ -f {{vm_dir}}/ncdata.qcow2 ] || qemu-img create -f qcow2 {{vm_dir}}/ncdata.qcow2 2T
    echo "Anaconda boots over VNC on {{vnc_bind}}:5900. Watch from your laptop with:"
    echo "    remote-viewer vnc://<this-host>:5900   # e.g. vnc://10.0.0.2:5900"
    echo "After install the ISO is ejected and the VM reboots into the installed system; verify with: just ssh"
    qemu-system-x86_64 \
        -m 6144 -smp 4,sockets=1,cores=2,threads=2 \
        -enable-kvm -cpu host -machine q35 \
        -drive if=pflash,format=raw,readonly=on,file={{ovmf_code}} \
        -drive if=pflash,format=raw,file={{vm_dir}}/OVMF_VARS_test.fd \
        -drive file={{raw_disk}},if=virtio,format=raw \
        -drive file={{vm_dir}}/ncdata.qcow2,if=virtio,format=qcow2 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443 \
        -device virtio-net-pci,netdev=net0 \
        -boot d -cdrom {{iso_file}} \
        -display none -vnc {{vnc_bind}}:0 -daemonize
    echo "Installer running in background over VNC {{vnc_bind}}:5900. Stop with: just stop"

# Use after `just run-iso` completes the install, to verify the installed system.

# Boot the installed raw OS disk in QEMU (UEFI); SSH in with `just ssh`.
run-disk:
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -f '[O]VMF_VARS_test.fd' || true
    sleep 1
    mkdir -p {{vm_dir}}
    [ -f {{vm_dir}}/OVMF_VARS_test.fd ] || cp {{ovmf_vars_src}} {{vm_dir}}/OVMF_VARS_test.fd
    [ -f {{vm_dir}}/ncdata.qcow2 ] || qemu-img create -f qcow2 {{vm_dir}}/ncdata.qcow2 2T
    echo "Booting installed disk. SSH: just ssh | VNC: remote-viewer vnc://<this-host>:5900"
    qemu-system-x86_64 \
        -m 6144 -smp 4,sockets=1,cores=2,threads=2 \
        -enable-kvm -cpu host -machine q35 \
        -drive if=pflash,format=raw,readonly=on,file={{ovmf_code}} \
        -drive if=pflash,format=raw,file={{vm_dir}}/OVMF_VARS_test.fd \
        -drive file={{raw_disk}},if=virtio,format=raw \
        -drive file={{vm_dir}}/ncdata.qcow2,if=virtio,format=qcow2 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443 \
        -device virtio-net-pci,netdev=net0 \
        -display none -vnc {{vnc_bind}}:0 -daemonize
    echo "Installed disk running in background. SSH: just ssh | VNC {{vnc_bind}}:5900 | Stop: just stop"

# SSH into the running VM (clears the stale host key first).
ssh:
    ssh-keygen -R '[127.0.0.1]:2222' >/dev/null 2>&1 || true
    ssh -p 2222 -l {{app_user}} 127.0.0.1

# Stop the running VM and remove the VM scratch dir (output/vm).
stop:
    pkill -f '[O]VMF_VARS_test.fd' || true
    rm -rf {{vm_dir}}
