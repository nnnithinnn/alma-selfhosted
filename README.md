# alma-selfhosted

An immutable, image-mode [bootc](https://github.com/containers/bootc) operating
system — built on **AlmaLinux 10** — for self-hosting a small set of services on
a single VPS. The whole OS is a signed, version-controlled container image:
updates are atomic `bootc upgrade`s with instant rollback, and nothing is
configured by hand on the box.

## What it runs

| Service | Role | Image source |
|---------|------|--------------|
| Caddy | Reverse proxy + automatic Let's Encrypt TLS | AWS ECR Public |
| Headscale | Self-hosted Tailscale control server (`vpn.nithin.nl`) | GHCR |
| Tailscale | Tailnet member **+ exit node** | GHCR |
| Nextcloud | File sync/share (`cld.nithin.nl`, public) | AWS ECR Public |
| PostgreSQL | Nextcloud database | AWS ECR Public |
| Valkey | Nextcloud cache | GHCR |

> No image is pulled from Docker Hub. App services run as **rootless** Podman
> Quadlets under the `nithin` user; Tailscale is the single rootful exception
> (an exit node must program the host's routing/NAT, which needs real
> `NET_ADMIN`).

## Host design

- **Base:** `quay.io/almalinuxorg/almalinux-bootc:10` (headless server), digest-pinned.
- **Debloated:** device firmware, microcode, AD/IPA SSSD, desktop disk tooling,
  etc. removed (~390 MB / 32% smaller install).
- **Storage:** two disks —
  - the **smallest disk** (≈60 GB NVMe) holds the OS and everything except
    Nextcloud user data (enforced by the kickstart `%pre` in `iso.toml`);
  - a dedicated **2 TB disk** holds Nextcloud user data only. It is
    auto-formatted XFS (label `ncdata`) on first boot if unlabeled and mounted
    at `/var/mnt/nextcloud`.
- **Access:** human admin `nithin` (wheel/sudo), **key-only SSH**, root account
  locked, password auth disabled.
- **Updates:** [Renovate](.github/renovate.json) opens PRs to bump the base
  image, Quadlet `Image=` digests, and GitHub Actions.

bootc reminder: `/usr` is read-only and `/etc` is merged on update — only
`/var` is persistent. All state and secrets live under `/var` and are never
baked into the image.

## Repository layout

```
Containerfile              # bootc image build (FROM + runs build.sh)
iso.toml                   # kickstart for ISO installs (disk selection, bootc switch)
Justfile                   # local build/test recipes (just)
files/
  scripts/                 # build-time scripts, run in numeric order by build.sh
    05-debloat.sh          #   strip server-irrelevant packages
    10-base.sh             #   base tweaks + enable storage units
    20-users.sh            #   lock root, subuid/subgid, perms
    90-signing.sh 91-* cleanup.sh   # template-provided, do not edit
  system/                  # files copied verbatim into the image (/ root)
    etc/containers/systemd/        # service Quadlets
    etc/ssh/, etc/sudoers.d/       # SSH hardening + sudo
    usr/lib/{sysusers,tmpfiles,sysctl}.d/   # declarative user/host config
    usr/libexec/, usr/lib/systemd/system/   # storage auto-init
.github/                   # CI: build container image + Renovate
```

## Building & testing locally

Requires [`just`](https://github.com/casey/just), `podman` (and
`qemu-system-x86_64` + `ovmf` for boot tests). Most recipes use `sudo`. Run
`just` with no arguments to list every recipe.

```sh
just build            # build the container image with Podman
just test-iso         # build a TEST installer ISO (boots the local image)
just run-iso          # boot an installer ISO in QEMU (tests the kickstart)
just run-disk         # boot the installed disk after run-iso finishes
just ssh              # SSH into the running VM (nithin@127.0.0.1:2222)
just stop             # stop the VM and clean up VM scratch
just prod-iso         # build PRODUCTION VPS media (private GHCR ref + creds)
just clean            # remove ./output build artifacts + Podman build cache
```

The build uses Podman's layer cache. If newly added files aren't picked up, run
`just clean` first to wipe the cache, then `just build`. All ephemeral VM
artifacts (writable OVMF vars, the 2 TB data disk, the console log) live under
`./output/vm`; nothing outside the working directory is written.

## CI

GitHub Actions ([`.github/workflows/`](.github/workflows/)) build and lint the
image on push/PR via the AlmaLinux `atomic-ci` pipeline, verifying the upstream
base signature with [`almalinux-bootc.pub`](almalinux-bootc.pub), then publish it
to GHCR. Renovate runs on a schedule. Installer ISOs are built locally with
`just test-iso` / `just prod-iso`, not in CI.

## Deploying / updating

Install from a built ISO, or `bootc switch` to the published image. Once
running, the system checks for updates in the background; apply manually with:

```sh
sudo bootc upgrade        # stage the latest image for next boot
sudo bootc rollback       # revert to the previous image
bootc status              # show current deployment
```

## Customizing

- Drop files to ship verbatim into [`files/system/`](files/system/) (paths and
  permissions are preserved).
- Add build steps as [`files/scripts/`](files/scripts/)`XX-name.sh` (run in
  numeric order). Do **not** edit `build.sh`, `cleanup.sh`, `90-signing.sh`, or
  `91-image-info.sh`.
