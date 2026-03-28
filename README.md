# homelab-core-services

> **Foundation service stack for Proxmox homelab: DNS ad-blocking, reverse proxy, password manager, remote access VPN.**
> One LXC per service — fault isolation, minimal blast radius, independent lifecycle management.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PVE](https://img.shields.io/badge/Proxmox_VE-8.x-orange)](https://www.proxmox.com)
[![AdGuard](https://img.shields.io/badge/AdGuard_Home-0.107.x-green)](https://github.com/AdguardTeam/AdGuardHome)

---

## Service Overview

| Service | LXC ID | IP | Port | Role |
|---|---|---|---|---|
| **AdGuard Home** | CT101 | `10.10.40.101` | 53 / 80 | DNS resolver + ad/tracker blocking |
| **Nginx Proxy Manager** | CT105 | `10.10.40.105` | 80 / 443 / 81 | Reverse proxy + Let's Encrypt SSL |
| **Tailscale** | CT106 | `10.10.40.106` | — | Remote access VPN (CGNAT/UDP-block tolerant) |
| **VaultWarden** | CT107 | `10.10.40.107` | 443 | Self-hosted Bitwarden-compatible password manager |

All IPs configurable via `configs/env`.

---

## Architecture

```
Internet
    │
    ▼
MikroTik Router (RouterOS 7)
    │  DNS upstream → AdGuard Home (CT101)
    │  Port forward 80/443 → NPM (CT105) [optional, if external access needed]
    │
    ├─ VLAN40 (SERVERS 10.10.40.0/24)
    │   ├── CT101 AdGuard       — answers all LAN DNS queries
    │   │         └── DNS rewrites for *.lan → NPM or direct IPs
    │   ├── CT105 NPM           — terminates HTTPS for all LAN services
    │   │         └── Let's Encrypt or self-signed certs
    │   ├── CT106 Tailscale     — site VPN + road warrior (DERP relay capable)
    │   └── CT107 VaultWarden   — HTTPS required; Caddy inside CT handles TLS
    │
    └─ VLAN20 (MAIN 10.10.20.0/24) — clients query CT101 for DNS
```

### Design decisions

**AdGuard as DNS authority (not MikroTik static DNS)**
MikroTik static DNS is adequate for simple A records but lacks per-entry priority, wildcard support, and a usable UI for rapid iteration. AdGuard DNS Rewrites handle `*.lan` with per-service granularity and survive router reboots without affecting LAN resolution.

**Grafana bypasses NPM**
NPM + Grafana WebSocket sessions are unreliable (proxy timeout on long-lived connections). `grafana.lan` has a direct AdGuard rewrite to `CT208:3000` — no NPM hop.

**VaultWarden uses Caddy (not NPM)**
VaultWarden requires HTTPS for all Bitwarden clients. Caddy runs inside CT107 with a self-signed cert, reducing inter-CT dependencies. NPM could proxy it, but adds an extra failure point for a security-critical service.

**Tailscale over WireGuard (for CGNAT/PPPoE environments)**
ISP-level UDP blocking prevents inbound WireGuard connections. Tailscale DERP relay servers punch through symmetric NAT — no port-forward configuration required. Exit node mode can also route all remote traffic through the homelab.

---

## Quick Start

```bash
# On pve-01 host:
git clone https://github.com/gaiagent0/homelab-core-services.git
cd homelab-core-services
cp configs/env.example configs/env
nano configs/env   # set IPs, VLAN tag, storage

# Deploy all 4 LXCs
bash scripts/deploy-all-lxcs.sh

# Individual service installs
bash adguard/install.sh
bash npm/install.sh
bash tailscale/install.sh
bash vaultwarden/install.sh
```

---

## Repository Structure

```
homelab-core-services/
├── README.md
├── docs/
│   └── adguard.md                — DNS rewrites, upstream config, MikroTik integration
├── configs/
│   └── env.example               — All configurable variables
├── scripts/
│   └── deploy-all-lxcs.sh        — Create all 4 LXCs on pve-01
├── adguard/
│   ├── install.sh                — AdGuard Home installer (CT101)
│   └── dns-rewrites.yaml         — Exportable DNS rewrite list (AdGuard 0.107+)
├── npm/
│   └── docker-compose.yml        — NPM Docker stack (CT105)
├── tailscale/
│   └── templates/systemd/
│       ├── tailscale-up.service  — Boot service (advertise-routes)
│       └── tailscale-up.sh       — Up script with ethtool GRO fix
└── vaultwarden/
    ├── docker-compose.yml        — VaultWarden container
    └── Caddyfile                 — Caddy HTTPS reverse proxy config
```

---

## LXC Creation Reference

```bash
# Variables: set in configs/env
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-zfs"
VLAN=40
GW="10.10.40.1"

# CT101 AdGuard
pct create 101 $TEMPLATE \
  --hostname adguard --memory 256 --swap 256 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.40.101/24,gw=$GW,tag=$VLAN \
  --storage $STORAGE --rootfs ${STORAGE}:4 \
  --unprivileged 1 --features nesting=1 --onboot 1 --startup order=10,up=60

# CT105 NPM
pct create 105 $TEMPLATE \
  --hostname npm --memory 512 --swap 512 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.40.105/24,gw=$GW,tag=$VLAN \
  --storage $STORAGE --rootfs ${STORAGE}:8 \
  --unprivileged 1 --features nesting=1 --onboot 1 --startup order=40,up=20

# CT106 Tailscale (requires TUN device passthrough)
pct create 106 $TEMPLATE \
  --hostname tailscale --memory 128 --swap 128 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.40.106/24,gw=$GW,tag=$VLAN \
  --storage $STORAGE --rootfs ${STORAGE}:2 \
  --unprivileged 1 --features nesting=1 --onboot 1 --startup order=20,up=30
# TUN device — add after creation:
echo "lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> /etc/pve/lxc/106.conf

# CT107 VaultWarden
pct create 107 $TEMPLATE \
  --hostname vaultwarden --memory 256 --swap 256 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=10.10.40.107/24,gw=$GW,tag=$VLAN \
  --storage $STORAGE --rootfs ${STORAGE}:4 \
  --unprivileged 1 --features nesting=1 --onboot 1 --startup order=30,up=20
```

---

## DNS Rewrite Reference

AdGuard Home → Filters → DNS Rewrites:

| Domain | Target | Via |
|---|---|---|
| `adguard.lan` | `10.10.40.101` | direct |
| `npm.lan` | `10.10.40.105` | direct (NPM admin UI) |
| `portainer.lan` | `10.10.40.105` | NPM → CT302:9000 |
| `gitea.lan` | `10.10.40.105` | NPM → CT302:3000 |
| `jellyfin.lan` | `10.10.40.105` | NPM → CT302:8096 |
| `jellyseerr.lan` | `10.10.40.105` | NPM → CT302:5055 |
| `pbs.lan` | `10.10.40.105` | NPM → CT201:8007 |
| `librenms.lan` | `10.10.40.105` | NPM → CT203:80 |
| `grafana.lan` | `10.10.40.208` | **direct** (skip NPM — WebSocket) |
| `vaultwarden.lan` | `10.10.40.107` | **direct** (Caddy inside CT) |
| `code.lan` | `10.10.40.105` | NPM → CT303:8080 |

---

## MikroTik Firewall Integration

```routeros
# Point all LAN DNS to AdGuard
/ip dns set servers=10.10.40.101 allow-remote-requests=yes

# Forward chain ACCEPT rules — MUST be before terminal DROP rule
/ip firewall filter
add chain=forward src-address=10.10.20.0/24 dst-address=10.10.40.101 \
    dst-port=53,80 protocol=tcp action=accept comment="MAIN→AdGuard"
add chain=forward src-address=10.10.20.0/24 dst-address=10.10.40.101 \
    dst-port=53 protocol=udp action=accept comment="MAIN→AdGuard DNS/UDP"
add chain=forward src-address=10.10.20.0/24 dst-address=10.10.40.105 \
    dst-port=80,443,81 protocol=tcp action=accept comment="MAIN→NPM"
add chain=forward src-address=10.10.20.0/24 dst-address=10.10.40.107 \
    dst-port=443 protocol=tcp action=accept comment="MAIN→VaultWarden"
```

> ⚠️ **Rule ordering is critical.** ACCEPT rules must precede the DROP terminal rule.
> Use explicit rule numbers with `place-before=` — never use Hungarian/special characters
> in `comment` selectors, as MikroTik `~` regex matching silently fails on non-ASCII.

---

## Security Notes

- **VaultWarden HTTPS** — mandatory for all Bitwarden clients. Self-signed cert requires:
  - Chrome: `chrome://flags/#unsafely-treat-insecure-origin-as-secure` → add `http://vaultwarden.lan`
  - Mobile apps: trust the self-signed CA, or use Cloudflare Tunnel for public HTTPS
- **AdGuard admin port** (3000 during setup, 80 after) — firewall to SERVERS VLAN only
- **NPM admin port 81** — firewall to management VLAN only, not MAIN clients
- **Tailscale ACLs** — restrict which Tailscale devices can access which LAN subnets via the Tailscale admin panel (`access-controls`)
- **VaultWarden signups** — set `SIGNUPS_ALLOWED=false` after creating your account

---

## AdGuard Startup Order

CT101 must start **before all DNS-dependent services**. With `order=10, up=60` pve-01 waits 60 seconds after AdGuard starts before proceeding to CT105/106/107. Without this, NPM and VaultWarden may fail DNS resolution during startup.

```bash
pct set 101 --onboot 1 --startup order=10,up=60
pct set 106 --onboot 1 --startup order=20,up=30
pct set 107 --onboot 1 --startup order=30,up=20
pct set 105 --onboot 1 --startup order=40,up=20
```

---

*Tested on: Proxmox VE 8.3 · AdGuard Home 0.107.57 · NPM 2.11.3 · VaultWarden 1.32.7 · Tailscale 1.80.x*