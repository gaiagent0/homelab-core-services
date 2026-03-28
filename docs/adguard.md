# AdGuard Home — Configuration Guide

## Initial setup
1. Access `http://CT101_IP:3000` for first-run wizard
2. Set admin credentials, bind DNS to all interfaces
3. After setup, access via `http://CT101_IP:80`

## MikroTik integration
```routeros
/ip dns set servers=10.10.40.101 allow-remote-requests=yes
```

## Internal DNS rewrites (examples)
| Domain | Target |
|---|---|
| `grafana.lan` | `10.10.40.208` (direct — skip NPM) |
| `portainer.lan` | `10.10.40.105` (via NPM) |
| `vaultwarden.lan` | `10.10.40.107` (direct — Caddy) |
| `*.lan` | NPM IP for all other services |

## Upstream DNS
- Primary: `94.140.14.14` (AdGuard DNS)
- Secondary: `1.1.1.1`
- Bootstrap: `9.9.9.9`

## Startup order (pve-01)
CT101 must start first (order=10, up=60) — DNS must be ready before dependents.
```bash
pct set 101 --onboot 1 --startup order=10,up=60
```
