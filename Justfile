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

# Login name baked into the image (read from config.env's APP_USER), used by the
# `ssh` recipe to log into the test VM.
app_user     := `sed -n 's/^APP_USER=//p' config.env | head -1`

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

# Remove all build outputs (./output, incl. VM scratch) and the Podman build cache.
clean:
    # Stop any running test VM first so it releases open files under ./output.
    # QEMU runs rootless (kvm group), so no sudo needed to kill it.
    pkill -f OVMF_VARS_test.fd || true
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
    pkill -f OVMF_VARS_test.fd || true
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
    pkill -f OVMF_VARS_test.fd || true
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
    pkill -f OVMF_VARS_test.fd || true
    rm -rf {{vm_dir}}
