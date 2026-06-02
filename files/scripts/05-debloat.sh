#!/usr/bin/env bash
#
# 05-debloat.sh — strip packages that are useless on a headless KVM/VPS bootc
# host, to shrink the image and reduce attack surface. Runs first so later
# customization operates on the slimmed base.
#
# Everything removed here was verified (dnf remove --assumeno) to NOT cascade
# into protected/essential packages (kernel, shim, sudo, podman, bootc, sshd,
# NetworkManager, SELinux, fwupd-which-shim-needs, etc.).

set -xeuo pipefail

# --- Device firmware: a virtualized guest has no real GPU/WiFi/audio NICs. ----
# (linux-firmware + the RHEL10 per-vendor split packages.) ~306 MB.
FIRMWARE=(
  linux-firmware
  linux-firmware-whence
  nvidia-gpu-firmware
  amd-gpu-firmware
  intel-gpu-firmware
  atheros-firmware
  mt7xxx-firmware
  brcmfmac-firmware
  realtek-firmware
  tiwilink-firmware
  intel-audio-firmware
  cirrus-audio-firmware
  nxpwireless-firmware
  amd-ucode-firmware
)

# --- Other server-irrelevant packages ----------------------------------------
EXTRA=(
  microcode_ctl       # CPU microcode is applied by the hypervisor, not the guest
  toolbox             # interactive dev-container tool; not for a server
  sos                 # RH support diagnostics bundle
  btrfs-progs         # this host is XFS-only
  samba-client-libs   # pulls AD/IPA sssd plugins we never use (no domain join)
  sequoia-sq          # Sequoia PGP CLI; pulls udisks2 (desktop disk automount)
  bluez               # Bluetooth stack; weak dep (Recommends) of fwupd. A
                      # headless VPS has no Bluetooth radio. Nothing hard-requires
                      # it, so fwupd (needed by shim/UEFI) is unaffected.
  avahi-libs          # mDNS/zeroconf library; orphaned leaf, no service uses it.
)

# dnf remove also cleans orphaned requirements (clean_requirements_on_remove=yes
# on RHEL/Alma), and runs offline from the rpmdb -- no network/metadata needed.
dnf -y remove "${FIRMWARE[@]}" "${EXTRA[@]}"
