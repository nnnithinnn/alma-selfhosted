# alma-selfhosted

[![Build image](https://github.com/nnnithinnn/alma-selfhosted/actions/workflows/build.yml/badge.svg)](https://github.com/nnnithinnn/alma-selfhosted/actions/workflows/build.yml)

An immutable, image-mode [bootc](https://github.com/containers/bootc) operating
system — built on **AlmaLinux 10** — for self-hosting a small set of services on
a single VPS. The whole OS is a signed, version-controlled container image:
updates are atomic `bootc upgrade`s with instant rollback, and nothing is
configured by hand on the box.

## What it runs

| Service | Role | Image source |
|---------|------|--------------|
| Caddy | Reverse proxy + automatic Let's Encrypt TLS | AWS ECR Public |
| Headscale | Self-hosted Tailscale control server (`vpn.example.com`) | GHCR |
| Tailscale | Tailnet member **+ exit node** | GHCR |
| Nextcloud | File sync/share (`cloud.example.com`, public) | AWS ECR Public |
| Collabora | In-browser office / document editing (same domain) | Docker Hub¹ |
| PostgreSQL | Nextcloud database | AWS ECR Public |
| Valkey | Nextcloud cache | GHCR |

> ¹ Collabora Online (CODE) is the **single, documented Docker Hub exception** —
> upstream publishes it only there. It is pulled anonymously and digest-pinned
> (auto-bumped by Renovate), giving the same supply-chain guarantee as a mirror.

> Apart from the single Collabora exception, no image is pulled from Docker Hub.
> App services run as **rootless** Podman Quadlets under a single app user
> (UID 1000; login name comes from `APP_USER` in
> [`config.env.template`](config.env.template)). Tailscale is the single rootful
> exception — an exit node must program the host's routing/NAT, which needs real
> `NET_ADMIN`.

> The published container image is **generic** — no personal info (domains, IPs,
> credentials, SSH key) is baked in. All deployment-specific values live in
> `/etc/selfhosted/config.env` on the installed system, written at install time
> from the kickstart and never published. See [Configuration](#configuration)
> below.

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
- **Access:** admin user set by `APP_USER` (default `app`, UID 1000, wheel/sudo),
  **key-only SSH**, root account locked, password auth disabled. User and SSH key
  are created at runtime by `selfhosted-configure.service` — nothing is baked.
- **Updates:** [Renovate](.github/renovate.json) opens PRs to bump the base
  image, Quadlet `Image=` digests, and GitHub Actions. The installed system pulls
  the latest image daily (`bootc-upgrade.timer`) and reboots if a new image is
  available.

bootc reminder: `/usr` is read-only and `/etc` is merged on update — only
`/var` is persistent. All state and secrets live under `/var` and are never
baked into the image.

## Tailscale exit node

The host is both a Headscale control server and a tailnet **exit node**, wired up
fully automatically on first boot — no manual `tailscale up`, no key copy-paste,
no route approval:

1. **`tailscale-authkey-init`** (a rootless *user* unit) waits for Headscale,
   ensures the `APP_USER` Headscale user exists, and mints a reusable pre-auth
   key tagged `tag:exit`, writing it (plus the derived hostname) atomically to
   `/var/lib/tailscale-bootstrap/authkey.env`.
2. **`tailscale-authkey.path`** (rootful) watches for that file and starts the
   **`tailscale.container`** node once it appears. The node enrolls with
   `--advertise-exit-node` against `https://HEADSCALE_HOST`.
3. The baked Headscale ACL policy auto-approves the exit route
   (`0.0.0.0/0` + `::/0`) for `tag:exit` via `autoApprovers`, so the route is
   live immediately.

Notes:

- The tailnet device name is the **label** of `HEADSCALE_HOST`
  (`vpn.example.com` → `vpn`), derived in the bootstrap script — no extra token.
- Tailscale is the **single rootful exception**: an exit node needs host
  networking, `/dev/net/tun`, `NET_ADMIN`/`NET_RAW` and host-wide IP forwarding
  (`90-ip-forward.conf`) to NAT tailnet egress. `41641/udp` is opened for direct
  peer connections.
- Caddy uses the Let's Encrypt **production** CA (not staging): Tailscale
  validates the Headscale control-server cert and rejects untrusted staging certs.
- **Re-enroll:** delete `/var/lib/tailscale-bootstrap/authkey.env` and restart
  `tailscale-authkey-init` (do this if the `headscale-data` or `tailscale-data`
  volume is wiped).

## Repository layout

```
config.env.template        # template for deployment config (gitignored config.env)
Containerfile              # bootc image build (FROM + runs build.sh)
iso.toml                   # kickstart for ISO installs (disk selection, bootc switch)
Justfile                   # local build/test recipes (just)
files/
  scripts/                 # build-time scripts, run in numeric order by build.sh
    05-debloat.sh          #   strip server-irrelevant packages
    10-base.sh             #   base tweaks + enable storage + selfhosted units
    15-selinux.sh          #   label baked container configs container_file_t
    20-users.sh            #   lock root, subuid/subgid for UID 1000
    25-network.sh          #   networking tweaks (sysctl, rp_filter)
    30-firewall.sh         #   firewalld: default-drop inbound, open service ports
    40-tailscale.sh        #   arm the rootful exit-node path trigger
    90-signing.sh 91-* cleanup.sh   # template-provided, do not edit
  base/                    # base OS + hardening  (copied to / at build time)
    etc/ssh/               #   SSH hardening (key-only, no root, no passwords)
    etc/motd.d/
    usr/lib/sysctl.d/      #   IP forwarding, unprivileged ports, kernel hardening
  services/                # the service stack   (copied to / at build time)
    usr/lib/selfhosted/
      configure            #   runtime config engine (runs as selfhosted-configure.service)
      templates/           #   @@TOKEN@@ source files; substituted at boot from config.env
    usr/bin/selfhosted     #   operational CLI (selfhosted status / upgrade)
    usr/libexec/           #   one-shot helpers: data-init, data-chown, apps-init, authkey
    usr/lib/systemd/system/#   system units: selfhosted-configure, data-init/chown, bootc-upgrade
    etc/containers/systemd/#   rootful Tailscale Quadlet
    etc/systemd/user/      #   rootless user units + timers (Quadlet dir, apps-init, etc.)
    etc/nextcloud/hooks/   #   Nextcloud post-installation occ hook
.github/                   # CI: build container image + Renovate
```

## Configuration

Deployment-specific values (domains, IPs, credentials, SSH key) are **never
baked into the published image**. They live in `/etc/selfhosted/config.env` on
the installed system, written once at install time by the Anaconda kickstart.

`selfhosted-configure.service` reads that file at every boot and applies
`@@TOKEN@@` substitution to produce all live config files from the templates
baked into `/usr/lib/selfhosted/templates/`. A hash of each template is stored
in `/var/lib/selfhosted/template-hashes/` so only changed templates are
re-applied across `bootc upgrade`s.

### Generating `config.env`

```sh
just config    # interactive wizard — prompts for every value, hashes the password,
               # reads the SSH key from a file, optionally writes ghcr-auth.json
```

Or copy [`config.env.template`](config.env.template) and fill it in manually.
`config.env` is gitignored — **never commit it**.

### Variables

| Section | Variable | Purpose |
|---------|----------|---------|
| **Identity** | `APP_USER` | OS login name for the admin user (UID 1000). |
| | `NEXTCLOUD_ADMIN_USER` | Nextcloud web admin account (first-run only). |
| **Domains** | `DOMAIN` | Base domain (informational). |
| | `HEADSCALE_HOST` | Headscale FQDN (`vpn.example.com`). |
| | `NEXTCLOUD_HOST` | Nextcloud FQDN (`cloud.example.com`). |
| | `MAGICDNS_BASE_DOMAIN` | Headscale MagicDNS domain — **must differ** from `HEADSCALE_HOST`'s domain. |
| | `ACME_EMAIL` | Let's Encrypt account contact. |
| **Nextcloud** | `NEXTCLOUD_PHONE_REGION` | ISO 3166-1 alpha-2 code for phone number formatting. |
| | `WEB_SUBNET` | Pinned `/24` for the rootless `web` container network; trusted as `TRUSTED_PROXIES`. |
| **Static networking** | `NET_MAC` | NIC MAC the static-IP profile binds to (blank = DHCP). |
| *(optional)* | `NET_IPV4_*` / `NET_IPV6_*` | Static IPv4/IPv6 address, gateway, DNS. |
| **Credentials** | `SSH_PUBKEY` | Full SSH public key string for the admin user. |
| | `APP_PASSWORD_HASH` | SHA-512 password hash (`openssl passwd -6`). |

## Building & testing locally

Requires [`just`](https://github.com/casey/just), `podman` (and
`qemu-system-x86_64` + `ovmf` for boot tests). Hybrid privilege model: the image
build and ISO step use `sudo` — bootc-image-builder needs rootful podman because
its experimental rootless mode relabels its store with SELinux contexts, which a
non-SELinux host (e.g. Debian) can't do. The QEMU boot/test loop is rootless.
Run `just` with no arguments to list every recipe.

```sh
just config       # generate config.env interactively (run before prod-iso)
just build        # build the container image with Podman
just test-iso     # build a TEST installer ISO (boots the local image, no config.env needed)
just run-iso      # boot an installer ISO in QEMU (tests the kickstart)
just run-disk     # boot the installed disk after run-iso finishes
just ssh          # SSH into the running VM (<APP_USER>@127.0.0.1:2222)
just stop         # stop the VM and clean up VM scratch
just prod-iso     # build PRODUCTION VPS media (private GHCR ref + creds + config.env)
just clean        # remove ./output build artifacts + Podman build cache
```

The build uses Podman's layer cache. If newly added files aren't picked up, run
`just clean` first to wipe the cache, then `just build`. All ephemeral VM
artifacts (writable OVMF vars, the 2 TB data disk, the console log) live under
`./output/vm`; nothing outside the working directory is written.

## CI

GitHub Actions ([`.github/workflows/`](.github/workflows/)) build and lint the
image on push/PR via the AlmaLinux `atomic-ci` pipeline, verifying the upstream
base signature with [`almalinux-bootc.pub`](almalinux-bootc.pub), then publish it
to GHCR. The published image is **generic** — CI has no `config.env` and builds
without one. Renovate runs on a schedule. Published main images are tagged
`latest`, an immutable respin version (`10.2.YYYYMMDD.N`), and an immutable
`sha-<commit>`. A cleanup workflow runs after each main build (and weekly) to
keep the 3 most recent builds and prune transient PR/per-arch tags. Installer
ISOs are built locally with `just test-iso` / `just prod-iso`, not in CI.

## Deploying / updating

Build a production ISO with `just prod-iso` (requires `config.env` and
`ghcr-auth.json`), install it on the VPS, then let `bootc-upgrade.timer` keep it
current. Or update manually:

```sh
selfhosted upgrade    # pull and stage the latest image (reboots on next boot)
selfhosted status     # show running containers
sudo bootc rollback   # revert to the previous image
bootc status          # show current deployment
```

## Customizing

- **Configuration:** run `just config` — see [Configuration](#configuration) above.
- **Add a service:** drop a new Quadlet file into
  `files/services/etc/containers/systemd/users/1000/` (rootless) or
  `files/services/etc/containers/systemd/` (rootful). Add any `@@TOKEN@@` the
  Quadlet needs to `config.env.template` and to the
  `files/services/usr/lib/selfhosted/templates/` tree, then register the new
  template in `files/services/usr/lib/selfhosted/configure`.
- **Add a build step:** create `files/scripts/XX-name.sh` (run in numeric order).
  Do **not** edit `build.sh`, `cleanup.sh`, `90-signing.sh`, or `91-image-info.sh`.
- **Drop static files:** place them in `files/base/` (OS + hardening) or
  `files/services/` (app stack). Paths mirror the target `/`; permissions are
  preserved by `cp -avf`.
