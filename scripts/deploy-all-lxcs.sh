#!/bin/bash
# Deploy all core service LXCs on pve-01
# Run as root on pve-01
# Source: https://github.com/gaiagent0/homelab-core-services
set -euo pipefail
source "$(dirname "$0")/../configs/env" 2>/dev/null || true

TEMPLATE="${LXC_TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
STORAGE="${LXC_STORAGE:-local-zfs}"
VLAN_TAG="${VLAN_TAG:-40}"
GW="${VLAN_GW:-10.10.40.1}"

create_ct() {
    local ID=$1 HOST=$2 IP=$3 RAM=$4 DISK=$5
    echo "Creating CT${ID} ${HOST} (${IP})..."
    pct create "$ID" "$TEMPLATE" \
        --hostname "$HOST" --memory "$RAM" --swap "$RAM" --cores 1 \
        --net0 "name=eth0,bridge=vmbr0,ip=${IP}/24,gw=${GW},tag=${VLAN_TAG}" \
        --storage "$STORAGE" --rootfs "${STORAGE}:${DISK}" \
        --unprivileged 1 --features nesting=1 --onboot 1 --start 1
    sleep 5
    pct exec "$ID" -- bash -c "echo nameserver 8.8.8.8 > /etc/resolv.conf && apt update -qq"
}

create_ct 101 "adguard"    "${ADGUARD_IP:-10.10.40.101}"    256  4
create_ct 105 "npm"        "${NPM_IP:-10.10.40.105}"        512  8
create_ct 106 "tailscale"  "${TAILSCALE_IP:-10.10.40.106}"  128  2
create_ct 107 "vaultwarden" "${VAULTWARDEN_IP:-10.10.40.107}" 256 4

echo "All CTs created. Install services:"
echo "  bash adguard/install.sh"
echo "  bash npm/install.sh"
echo "  bash tailscale/install.sh"
echo "  bash vaultwarden/install.sh"
