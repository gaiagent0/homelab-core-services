# CT-304 infra migrációs runbook (pve-ai-agent)

**CT-304 = `pve-ai-agent`** — Debian 12 LXC, a Hermes Agent bot-háló futtató konténere.
Ez a runbook a CT-304 pve-03 → pve-02 migrációt, az erőforrás-beállításokat, a hálózatot,
az SSH-hozzáférést és a konténeren belüli szolgáltatásokat dokumentálja.

## 1. Konténer áttekintés

| Tulajdonság | Érték |
|---|---|
| VMID | 304 |
| Név | pve-ai-agent |
| OS | Debian 12 (LXC) |
| IP | 10.10.40.210/24 |
| Jelenlegi node | pve-03 (10.10.40.13) — **cél: pve-02** (10.10.40.12) |
| Storage | local-zfs (`rpool/data/subvol-304-disk-0`, 99G lemez) |
| RAM | jelenleg ~8 GB (a migráció részeként **10 GB-ra** emelendő) |
| Cores / Swap | 6 cores / 2048 MB swap |

Cluster állapot (2026-08-25): 3 node, quorate OK.
pve-02 = 10.10.40.12 (RAM 8.2 GB össz., ~27% használt) — ezen van hely a bővítéshez.

## 2. Migráció lépései

Futtatható bármelyik másik node-ról vagy a Proxmox web UI-ból:

```bash
# 0. (opcionális) rollback pont: PBS backup
vzdump 304 --storage pbs-server --mode snapshot --compress zstd

# 1. Migráció pve-02-re (online = snapshotos másolás; a CT leáll, majd célon indul)
pct migrate 304 pve-02 --online

# 2. RAM emelés 10 GB-ra
pct set 304 -memory 10240

# 3. Ellenőrzés
pct status 304
ssh root@10.10.40.210 'free -m'
```

**Fontos:**
- A migráció LEÁLLÍTJA a CT-t → minden Hermes session megszakad, újraindulás után ugyanazon IP-n folytatható.
- `local-zfs → local-zfs` támogatott; pve-02-n a local-zfs gyakorlatilag üres.
- Visszagörgetés PBS mentés nélkül is: `pct migrate 304 pve-03`.
- `--online` LXC-nél nem élő vándorlás, hanem snapshot + restore.

## 3. Hálózat

- Statikus IP: **10.10.40.210/24**, gateway a homelab VLAN-on (10.10.40.1).
- SSH: port 22, root kulcsos hozzáférés.
- Laptop hozzáférés: lásd a `CT304_TO_LAPTOP_ACCESS.md` jegyzetet (SSH kulcs telepítése a laptopról).
- Kimenő forgalom: AdGuard DNS + NPM proxy mögötti hálózati lánc (AdGuard → NPM → Vaultwarden/Tailscale).

## 4. SSH hozzáférés

```bash
ssh root@10.10.40.210        # közvetlen
ssh -t root@10.10.40.210 herdr   # egyből a bot-háló TUI-ba
```

## 5. Bot-háló: herdr setup (8 profil)

A konténeren 8 Hermes profil fut, két herdr workspace-ben (4+4), kezelő szkript:
`/root/bin/hermes-bots-herdr.sh`

- **w1 "ops"**: rendszergazda, orszem, kutato, biztonsagor
- **w3 "tartalom"**: iro, fejleszto, hirado, kodolo

Használat:
```bash
/root/bin/hermes-bots-herdr.sh      # mindkét workspace építése/ellenőrzése
/root/bin/hermes-bots-herdr.sh w1   # csak ops
/root/bin/hermes-bots-herdr.sh w3   # csak tartalom
```
Workspace váltás: Ctrl+B + szám; sidebar: Ctrl+B + b.
Migráció után újraépítés: a szkript kihagyja a már kész workspace-eket, hiányzó pane-eket pótolja.

### Profilok és modellek

| Profil | Szerep | Modell (nous provider) |
|---|---|---|
| rendszergazda | IT admin, CT-304 üzemeltető | stealth/ox-alpha |
| orszem | felügyelet/ellenőrzés | stepfun/step-3.7-flash:free |
| kutato | kutatás | meituan/longcat-2.0:free |
| biztonsagor | változtatási zár, jóváhagyás | stealth/ox-alpha |
| iro | tartalomírás | upstage/solar-pro4:free |
| fejleszto | fejlesztés | poolside/laguna-s-2.1:free |
| hirado | hírek/kommunikáció | upstage/solar-pro4:free |
| kodolo | kódolási feladatok | poolside/laguna-xs-2.1:free |

(+ `proxi66` profil: tencent/hy3:free — nincs benne a herdr-ben.)

Profil home-ok: `/root/.hermes/profiles/<név>/`.

## 6. systemd user timer-ek (hermes-cron-*)

User-szintű systemd egységek: `~/.config/systemd/user/hermes-cron-{profil}.{timer,service}`
Aktív profilokra: **rendszergazda, orszem, kutato, biztonsagor, iro, hirado** (6 timer).

Példa (rendszergazda):
```ini
# hermes-cron-rendszergazda.timer
[Timer]
OnCalendar=*-*-* *:*:30
Persistent=true

# hermes-cron-rendszergazda.service
[Service]
Type=oneshot
Environment="HERMES_HOME=/root/.hermes/profiles/rendszergazda"
ExecStart=/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli.main --profile rendszergazda cron tick
TimeoutStartSec=1800
```

Ellenőrzés migráció után:
```bash
systemctl --user list-timers | grep hermes-cron
```

Rendszer-szintű cron (root crontab): `/opt/pve-agent/agent.py` heartbeat (5 perc), telegram-poll (2 perc), daily-report (07:00).

Egyéb service-ek: `hermes-gateway.service`, `hermes-coord.service` (system), `hermes-gateway-<profil>.service` (user, 6 db).

## 7. Backup megfontolások

- **PBS:** napi vzdump job a clusteren; migráció előtt ajánlott kézi rollback pont (`vzdump 304 --storage pbs-server --mode snapshot --compress zstd`).
- **Storage:** rootfs local-zfs subvol — snapshot-képes, gyors restore.
- A konténeren belüli állapot (`/root/.hermes/`, profile-ok, `.env`) a vzdumpba beletartozik; külső rclone sync a hosszú távú másolat.
- ⚠️ Titkok: a `.env` fájl tokeneket tartalmaz — repóba SOHA ne kerüljön, csak backupban.

## 8. Migráció utáni checklist

1. `pct status 304` — running pve-02-n
2. `ssh root@10.10.40.210 'free -m'` — 10 GB RAM látszik
3. `systemctl status hermes-gateway` és `systemctl --user list-timers | grep hermes-cron`
4. `/root/bin/hermes-bots-herdr.sh` — workspaces újjáépítése
5. Gateway-ek és bot-válaszok tesztje (Telegram/Discord)
