# High Availability — Node-Affinity Failover (pve-01 → pve-02)

> Added 2026-08-26. Covers HA protection for CT101 (adguard), CT105 (npm),
> CT106 (tailscale), CT107 (vaultwarden). CT150 (mcp-server, separate repo)
> is also covered by the same HA group.

## Summary

All four core services in this repo run on **pve-01** as primary, with
**pve-02** as the automatic failover target. If pve-01 goes down, Proxmox's
`pve-ha-crm` / `pve-ha-lrm` stack relocates and starts each CT on pve-02
within roughly 1-2 minutes, using a ZFS-replicated copy of the container disk.

```
pve-01 (primary, priority 2)  --ZFS replication (*/15)-->  pve-02 (failover, priority 1)
  ct:101 adguard
  ct:105 npm
  ct:106 tailscale
  ct:107 vaultwarden
  ct:150 mcp-server (see proxmox-mcp repo)
```

## Prerequisites (already applied cluster-wide)

- `softdog` kernel module loaded and persisted via
  `/etc/modules-load.d/softdog.conf` on **all three nodes** -- required for
  HA fencing/watchdog. Without this, `pve-ha-crm` will not arm.
- All HA-managed CTs must live on **shared-name ZFS storage** (`local-zfs`),
  not the plain `local` (dir) storage. `local` volumes cannot be replicated
  by `pvesr`. CT101 and CT150 were migrated from `local` -> `local-zfs` via
  `pct move-volume <vmid> rootfs local-zfs --delete 1` prior to enabling HA.
  CT105/106/107 were already on `local-zfs`.

## HA rule configuration

Proxmox VE 9.x replaced HA groups with **HA rules**. The relevant rule:

```bash
ha-manager rules add node-affinity core-services \
  --nodes "pve-01:2,pve-02:1" \
  --resources "ct:101,ct:105,ct:106,ct:107,ct:150" \
  --strict 0
```

- `pve-01:2` -- higher priority, preferred/active node.
- `pve-02:1` -- lower priority, failover target.
- `--strict 0` -- non-strict, so the CRM may fall back to pve-03 in a
  worst-case scenario where both pve-01 and pve-02 are unavailable.

Resources were registered individually before the rule, e.g.:

```bash
ha-manager add ct:101 --max_restart 2 --max_relocate 2
ha-manager add ct:105 --max_restart 2 --max_relocate 2
ha-manager add ct:106 --max_restart 2 --max_relocate 2
ha-manager add ct:107 --max_restart 2 --max_relocate 2
```

## ZFS replication jobs

Each CT replicates to pve-02 every 15 minutes:

```bash
pvesr create-local-job 101-0 pve-02 --schedule '*/15'
pvesr create-local-job 105-0 pve-02 --schedule '*/15'
pvesr create-local-job 106-0 pve-02 --schedule '*/15'
pvesr create-local-job 107-0 pve-02 --schedule '*/15'
```

Check status: `pvesr list` / `pvesr status`. Manual sync: `pvesr run --id <job-id> --verbose`.

**Data-loss window:** up to 15 minutes of writes inside the CT (config
changes, VaultWarden vault entries, AdGuard query logs, etc.) since the last
replication cycle are not present on pve-02 at failover time. For
VaultWarden in particular, treat this as informational -- the authoritative
backup for vault data is still the regular PBS backup job, not replication.

## Verifying failover readiness

```bash
ha-manager status
# Expect: quorum OK, fencing armed (CRM watchdog active),
#         service ct:101 (pve-01, started), etc.

pvesr list
# Expect: all jobs "Enabled: yes", recent successful run in `pvesr status`
```

If `ha-manager status` shows `fencing disarmed` with resources stuck in
`queued`, the stack may be in a frozen/disarmed state left over from a prior
manual `crm-command disarm-ha`. Re-arm with:

```bash
ha-manager crm-command arm-ha
```

## Known limitations

- Failover is CT-relocation, not live migration -- there is a restart, not a
  hot migrate. Expect a brief (seconds) outage of DNS/proxy/VPN/vault during
  actual failover, on top of the up-to-15-minute data staleness above.
- pve-02 has the smallest physical RAM in the cluster (7.6 GB). The five
  HA-managed CTs' combined memory *limits* total ~2.1 GB, well within
  pve-02's free capacity even accounting for CT304 (pve-ai-agent) also
  running there -- but re-check headroom before adding further CTs to this
  HA group.
