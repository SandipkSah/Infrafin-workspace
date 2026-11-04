# Deploying the Amfileon monitoring setup

```
all hosts:  dockprom's exporters ──► Alloy (/srv/docker/alloy) ──push, TLS + auth──┬──► Prometheus db1 ── rules ──► Alertmanager ──► team channel
                                                                                  │    (/srv/docker/prometheus)          └─ Watchdog ──► healthchecks.io
                                                                                  └──► Prometheus db2 (copy, no rules)
Grafana (dockprom, db1): datasources db1.prometheus.amf + db2.prometheus.amf
```

Validated in [`../local-rehearsal/`](../local-rehearsal/) (44 checks incl. a 10-minute db1 outage
with full back-fill). Hosts: db1, db2, cpu1, cpu2, gpu1, prod3 (prod4 later).

**Rule for every step:** Claude prepares and stages files (ssh/scp as `ssa`, no root); every
`sudo` / `docker` command is run by a person. Secrets live only in `.env` files and are never
printed.

## Order

| # | Step | Runbook | Verify |
|---|---|---|---|
| 0 | Generate secrets on your Mac | `./gen-secrets.sh` | store passwords in Infisical |
| 1 | Prometheus on **db2** | [db2/INSTALL.md](db2/INSTALL.md) | `./verify-prometheus.sh db2` |
| 2 | Prometheus + Alertmanager on **db1** | [db1/INSTALL.md](db1/INSTALL.md) | `./verify-prometheus.sh db1`, healthchecks.io shows "up" |
| 3 | Alloy on **cpu2** (pilot) | [alloy/INSTALL.md](alloy/INSTALL.md) | `./verify-host.sh cpu2` |
| 4 | Alloy on db1, db2, cpu1, gpu1, prod3 | same | `./verify-host.sh <host>` |
| 5 | Grafana with all dashboards on db1 (`https://grafana.amf`) | [db1/grafana/INSTALL.md](db1/grafana/INSTALL.md) | log in, Fleet shows 6 hosts |
| 6 | **Lock down permissions** | below | `ssa` can no longer write |

> **Open item — Watchdog heartbeat not set up yet (2026-10-26).** `HEALTHCHECKS_PING_URL` in
> db1's `.env` is empty, so the Watchdog is discarded and **nothing pages anyone if db1 itself
> dies**. All other alerts work. To enable: create the healthchecks.io check (period 1 min,
> grace 5 min), run `./fill-db1-env.sh` and paste the URL, then
> `ssh -t db1 'cd /srv/docker/prometheus && sudo docker compose up -d alertmanager'`.

## 5. Grafana (`https://grafana.amf`)

Own Grafana on db1 with both datasources and all dashboards provisioned — see
[db1/grafana/INSTALL.md](db1/grafana/INSTALL.md). dockprom's Grafana (`grafana.db1.amf`) is not changed.

## 6. Final step — lock down permissions (mandatory, after everything is verified)

During the rollout the files under `/srv/docker/{prometheus,alloy}` are owned by `ssa` (copied
from the staging folder), so configs can still be adjusted. Once everything works, make them match
the existing services (`/srv/docker/dockprom`, `proxy`, …: `root:root`, dirs 755, files 644), so
`ssa` — and therefore Claude — can no longer edit them. On **every** host:

```bash
for d in /srv/docker/prometheus /srv/docker/alloy /srv/docker/grafana-dashboards; do
  [ -d "$d" ] || continue
  sudo chown -R root:root "$d"
  sudo find "$d" -type d -exec chmod 755 {} +
  sudo find "$d" -type f -exec chmod 644 {} +
  sudo chmod 600 "$d/.env"      # decision: 600 (recommended) or leave 644 like the other services' .env
  [ -f "$d/redis.env" ] && sudo chmod 600 "$d/redis.env"   # Redis passwords: always 600
done
stat -c '%A %U:%G %n' /srv/docker/prometheus /srv/docker/alloy /srv/docker/*/.env 2>/dev/null | grep -E 'prometheus|alloy'
```
Containers keep running; nothing needs restarting (the files are read-only mounts).
Check afterwards, as `ssa`: `test -w /srv/docker/alloy/config/common.alloy && echo WRITABLE || echo locked`.
