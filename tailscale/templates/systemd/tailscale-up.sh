#!/bin/bash
sleep 5
tailscale up --advertise-routes=10.10.40.0/24 --accept-dns=false
