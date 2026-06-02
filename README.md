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
> Quadlets under a single app user (the login name comes from `APP_USER` in
> [`config.env`](config.env), default `cld`); Tailscale is the single rootful
> exception (an exit node must program the host's routing/NAT, which needs real
> `NET_ADMIN`).

> All deployment-specific values — domains, ACME email, the app user name,
> static networking — live in one file, [`config.env`](config.env). They are
> substituted into the baked configs at build time, so re-deploying for a
> different host/person means editing that one file (and swapping the SSH key).

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
- **Access:** human admin set by `APP_USER` in `config.env` (default `cld`,
  wheel/sudo), **key-only SSH**, root account locked, password auth disabled.
- **Updates:** [Renovate](.github/renovate.json) opens PRs to bump the base
  image, Quadlet `Image=` digests, and GitHub Actions.

bootc reminder: `/usr` is read-only and `/etc` is merged on update — only
`/var` is persistent. All state and secrets live under `/var` and are never
baked into the image.

## Repository layout

```
config.env                 # SINGLE source of truth for all customizations
Containerfile              # bootc image build (FROM + runs build.sh)
iso.toml                   # kickstart for ISO installs (disk selection, bootc switch)
Justfile                   # local build/test recipes (just)
files/
  scripts/                 # build-time scripts, run in numeric order by build.sh
    00-config.sh           #   substitute config.env @@TOKENS@@ into baked files
    05-debloat.sh          #   strip server-irrelevant packages
    10-base.sh             #   base tweaks + enable storage units
    20-users.sh            #   lock root, subuid/subgid, perms
    90-signing.sh 91-* cleanup.sh   # template-provided, do not edit
  base/                    # 1) base OS + hardening    -> copied to / (in order)
    etc/ssh/, etc/sudoers.d/, etc/motd.d/
    usr/lib/{sysusers,tmpfiles,sysctl}.d/
  services/                # 2) the service stack      -> copied to /
    etc/caddy/, etc/headscale/, etc/nextcloud/
    etc/containers/systemd/        # service Quadlets (incl. rootful tailscale)
    etc/systemd/, usr/libexec/, usr/lib/systemd/system/   # units + storage init
  optionals/               # 3) deploy-specific extras  -> copied to /
    etc/NetworkManager/system-connections/   # static-IP profile (by MAC)
.github/                   # CI: build container image + Renovate
```

## Configuration (`config.env`)

[`config.env`](config.env) is the **single source of truth** for every
deployment-specific value. `build.sh` sources it and `00-config.sh` substitutes
the `@@TOKEN@@` placeholders found in `files/{base,services,optionals}` at build
time — so re-deploying for a different host/person means editing this one file
(and swapping the SSH public key). Format is `KEY=value` (no spaces around `=`);
quote any value containing shell metacharacters such as `;` (the DNS lists).

| Section | Variable | Purpose | Default |
|---------|----------|---------|---------|
| **Identity** | `APP_USER` | Login / sudo / SSH-key owner + rootless Podman namespace owner (Quadlet dir is keyed by UID 1000). By convention the same as the Nextcloud subdomain. | `cld` |
| | `NEXTCLOUD_ADMIN_USER` | Nextcloud's initial web admin account (first-run only). | `cld` |
| **Domains** | `DOMAIN` | Base domain (reference only; hosts below are fully qualified). | `nithin.nl` |
| | `HEADSCALE_HOST` | Headscale control server FQDN (Caddy terminates TLS). | `vpn.nithin.nl` |
| | `NEXTCLOUD_HOST` | Nextcloud public FQDN. | `cld.nithin.nl` |
| | `MAGICDNS_BASE_DOMAIN` | Headscale MagicDNS base domain — **must differ** from `HEADSCALE_HOST`'s domain. | `mesh.nithin.nl` |
| | `ACME_EMAIL` | Let's Encrypt account contact (expiry/recovery notices). | `hi@nithin.nl` |
| **Nextcloud** | `NEXTCLOUD_PHONE_REGION` | Default region for parsing phone numbers (ISO 3166-1 alpha-2). | `IN` |
| | `WEB_SUBNET` | Pinned subnet for the rootless `web` network; trusted as `TRUSTED_PROXIES`. | `10.10.10.0/24` |
| **Static networking** | `NET_MAC` | NIC MAC the static-IP profile binds to (so it only activates on the real VPS; QEMU keeps DHCP). | — |
| (`files/optionals`) | `NET_IPV4_CIDR` / `NET_IPV4_ADDR` / `NET_IPV4_GATEWAY` | IPv4 address (CIDR + bare), gateway — **mandatory** (host unreachable if it fails). | — |
| | `NET_IPV4_DNS` | Quoted, `;`-separated IPv4 resolvers. | `"1.1.1.1;9.9.9.9;"` |
| | `NET_IPV6_ADDR` / `NET_IPV6_1..4` / `NET_IPV6_GATEWAY` | Primary IPv6 + all four assigned addresses + gateway (best-effort; gateway sits in a different `/64`). | — |
| | `NET_IPV6_DNS` | Quoted, `;`-separated IPv6 resolvers. | `"2606:4700:4700::1111;2620:fe::fe;"` |

## Building & testing locally

Requires [`just`](https://github.com/casey/just), `podman` (and
`qemu-system-x86_64` + `ovmf` for boot tests). Most recipes use `sudo`. Run
`just` with no arguments to list every recipe.

```sh
just build            # build the container image with Podman
just test-iso         # build a TEST installer ISO (boots the local image)
just run-iso          # boot an installer ISO in QEMU (tests the kickstart)
just run-disk         # boot the installed disk after run-iso finishes
just ssh              # SSH into the running VM (<APP_USER>@127.0.0.1:2222)
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
to GHCR. Renovate runs on a schedule. A weekly cleanup workflow prunes old GHCR
image versions, keeping the 3 most recent builds. Installer ISOs are built
locally with `just test-iso` / `just prod-iso`, not in CI.

## Deploying / updating

Install from a built ISO, or `bootc switch` to the published image. Once
running, the system checks for updates in the background; apply manually with:

```sh
sudo bootc upgrade        # stage the latest image for next boot
sudo bootc rollback       # revert to the previous image
bootc status              # show current deployment
```

## Customizing

- **First stop:** edit [`config.env`](config.env) — see the
  [Configuration](#configuration-configenv) section above for every variable.
  Build scripts substitute the `@@TOKEN@@` placeholders in the baked files at
  build time, and the SSH key file is renamed to match `APP_USER`. Swap your own
  public key in
  [`files/base/etc/ssh/authorized_keys.d/`](files/base/etc/ssh/authorized_keys.d/).
- Drop files to ship verbatim into one of the three trees by purpose:
  [`files/base/`](files/base/) (OS + hardening),
  [`files/services/`](files/services/) (the app stack), or
  [`files/optionals/`](files/optionals/) (deploy-specific extras). Paths and
  permissions are preserved; everything is copied to `/` in that order.
- Add build steps as [`files/scripts/`](files/scripts/)`XX-name.sh` (run in
  numeric order). Do **not** edit `build.sh`, `cleanup.sh`, `90-signing.sh`, or
  `91-image-info.sh`.
