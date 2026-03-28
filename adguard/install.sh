#!/bin/bash
# Install AdGuard Home in CT101
pct exec 101 -- bash -c "
echo nameserver 8.8.8.8 > /etc/resolv.conf
apt update -qq && apt install -y curl -qq
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
"
echo "AdGuard Home installed. Access: http://$(pct exec 101 -- hostname -I | awk '{print $1}'):3000"
