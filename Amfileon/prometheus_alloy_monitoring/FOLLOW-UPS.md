# Monitoring rollout — open items

Status as of 2026-11-13. Metrics: Alloy on **9 hosts** (7 Linux + prod1, prod2 Windows) → Prometheus db1 +
db2, alerting on db1, Grafana at <https://grafana.amf> (authentik SSO), certificate checks for 92 names.
Logs: Alloy on all 9 hosts (containers + journal; Windows event logs) → Loki on db1 (30 days), searchable
in grafana.amf.

## Open now (2026-11-13) — short list

| # | Item | Who | Where |
|---|---|---|---|
| 1 | **cpu2 and gpu1 system disks** — were almost full (2026-11-12: cpu2 `/` 33 GB, −60 GB/day; gpu1 `/` 5 GB); **2026-11-13 partly cleaned: cpu2 81 GB, gpu1 33 GB free** — watch it — data written *inside* the conda containers: cpu2 `conda-jba` 155 GB, `conda-ttr` 62 GB; gpu1 `conda-she` 115 GB. `HostDiskAlmostFull` is firing | the users jba, ttr, she | move data to `/home` or `/home/shared` (TBs free) |
| 2 | **db1 Redis 8 (`/srv/docker/redis`, :36379) has no password** — set one, then `fill-redis-env.sh` on db1; is this redis8 group still used? | its owner | Changes 2026-11-13 |
| 3 | `local-log-retention.sh --apply` — **done on 6 hosts (2026-11-11/13); only cpu2 left** (was overloaded: load 249 on 64 cores) | you | Changes 2026-11-11 |
| 4 | ~~Docker log limit on db1 and db2~~ — **done 2026-11-13** (all 7 Linux hosts limited; prod3 had `512m×2` already). `init: true` for zombie containers stays with Rudi (db1: 140k zombies) | Rudi | Maintenance window → Status |
| 5 | Big unlimited Docker logs, owners recreate when convenient: prod4 Mongo production 60.7 GB, gpu1 nginx-proxy 11 GB (helps gpu1's disk), … | owners | Maintenance window → Status |
| 6 | Findings for owners: **filebeat keeps rotated/deleted Docker logs open** (needs `close_removed: true`, `close_inactive: 5m`; until then restart it now and then); dockprom Alertmanager cannot deliver to Slack; Grafana admin password in cpu1 dockprom override (rotate); promtail configs world-readable; prod1 Windows firewall not effective; `preview.dagster.amf` certificate check failing since ≥ 2026-11-11 | owners | Security findings |
| 7 | Watchdog heartbeat (healthchecks.io) — nothing pages anyone if db1 itself dies | ops | Pending steps #1 |
| 8 | Commit this work to git (branch `monitoring/alloy-prometheus`) | you | — |
| 9 | **db2: containers labelled `logging=promtail` reach no Loki** — Alloy skips them (promtail is meant to ship them), but db2 has no promtail (e.g. the ETL/Dagster containers). Let Alloy collect them on hosts without promtail | you | Changes 2026-11-13 |
| 12 | **Zombie processes (`init: true`)** — cpu1: dockprom Grafana (healthcheck `wget https://hc.amf/…` leaves one `ssl_client` per minute; 246k cleared 2026-11-12 by restart, will come back). **db1 ~142k / db2 ~172k processes**: db1's top parents ≈ 25.8k each = a ClickHouse keeper, a Grafana (uid 472 — not our grafana-dashboards, it has no healthcheck), a `sleep` container; **db2 not identified yet**. Next: get the container names with the command below, then `init: true` under each service + `docker compose up -d <service>` (Rudi). Name lookup (read-only, root): `sudo ps -eo ppid=,stat= \| awk '$2~/^Z/{print $1}' \| sort \| uniq -c \| sort -rn \| head` → `cat /proc/<ppid>/cgroup` → container id → `docker ps --no-trunc` | you + Rudi | Maintenance window → Why |
| 11 | **prod1 TimeBase JVM (after Saturday's TimeBase restart with the JMX agent):** check `up{job="timebase-jvm"}`=1, then add alerts (heap > 85 % for 2 min; JVM metrics missing; handle count rising — baseline ~260k) and drop `timebase-jvm` from the ExporterDown exemption | you | `deploy/alloy/windows/handover-prod1-2026-11-13/README.md` |
| 13 | ~~db1 Loki has no data volume~~ — **done 2026-11-13 16:21** (`add-loki-volume.sh --apply`, 0 lines lost, 28 GB log freed). Left: delete `/root/loki-data-backup-2026-11-13-162108` (61 MB) on db1 after a few days | you | Changes 2026-11-13 |
| 10 | Tell the ETL/Dagster owner: 4 stopped containers on db2 have `restart: always` and came back on a Docker restart (see Changes 2026-11-13) — remove them or use `restart: unless-stopped`; `identifier_mappings_v9` runs unhealthy for 2 weeks | you → owner | Changes 2026-11-13 |

## Pending steps of this rollout

| # | Item | Who | Notes |
|---|---|---|---|
| 1 | Watchdog heartbeat | ops | Create the healthchecks.io check (period 1 min, grace 5 min), run `deploy/fill-db1-env.sh`, restart alertmanager. **Until then nothing pages anyone if db1 itself dies.** |
| 2 | ~~Alert recipient → team address~~ — `.env` changed 2026-10-28 | ops | takes effect after `cd /srv/docker/prometheus && sudo docker compose up -d alertmanager` (a plain restart keeps the old address) |
| 3 | Dashboards on db1 — **own Grafana at `https://grafana.amf`** (decided 2026-10-28; dockprom's Grafana stays untouched) | you | **installed 2026-10-28**, verified via db1 (TLS ok, HTTP 200). Missing: DNS A record `grafana.amf → 10.10.10.20` |
| 4 | ~~Commit to git~~ — done: `ce5cb90` on branch `monitoring/alloy-prometheus` (not pushed/merged) | you | review, then merge/push |
| 5 | **Final lockdown** of `/srv/docker/{prometheus,alloy}` on every host + `grafana-dashboards` on db1 | ops (root) | `deploy/README.md` step 6 — must be the last step |
| 6 | ~~prod4~~ — live and locked down 2026-10-30 (exporters, 3 ClickHouse servers, 6 Redis) | ops | Off: `redis-staging-prod4` (crash-looping), keepers. Out of scope: `redis-test-server`, `redis-stack-server`, `redis-sentinel` (`redis:8`) |
| 7 | **ClickHouse / Redis / GitLab metrics** (2026-10-28) — **Redis live** (12 instances, 8 via verified TLS), **GitLab live** (4 endpoints, `gitlab.rb` + reconfigure done 15:45), `services` alert rules live. **ClickHouse still off** (needs `enable-clickhouse-metrics.sh` per container). Staged, not yet active on db1: filter for `gitlab_ruby_threads_*` (−900 series) — takes effect at the next Alloy restart | you (discovery, Redis script) + owners (ClickHouse/GitLab config) | `deploy/services/INSTALL.md`. Rehearsed locally 2026-10-28 (`services-rehearsal/`: real ClickHouse+Keeper, TLS Redis+sentinel, GitLab CE, generated Alloy config, real alert rules) — all dashboards fill; series trimmed (GitLab 16k→3.8k, ClickHouse −27 %). Then db1's alert.rules must be re-staged (`./stage.sh prometheus db1` + reload) for the new rules |

## Maintenance window (weekend, with Rudi's `init: true` slot) — Docker log limit + zombie fix

**To do later; nothing of this is done yet.** Both need containers to be recreated, so one window covers both.

### Why

| Problem | Where | Effect |
|---|---|---|
| Docker container logs have **no size limit** (`json-file`, no `log-opts`) | db1, db2, cpu1, cpu2, gpu1, prod4 (prod3 has `max-size 512m, max-file 2`) | logs grow until the container is recreated — db1: >180 million old lines; also makes Alloy's first start slow (it reads every line) |
| Containers without an init process collect **zombie processes** — their healthcheck children are never reaped by PID 1 | db1: **127,321** (≈25,800 each from a ClickHouse keeper, a Grafana, a `sleep` container, …; 1/min since the last restart 18 days ago). cpu1: dockprom's Grafana had 246,482 since May — **cleared 2026-11-11** by `docker compose restart grafana`, will come back | harmless today (no CPU, no open files; PIDs 6 % of 4.19 M), but they slow down everything that scans all processes (`ps`, cAdvisor, monitoring). (Separate issue, not caused by zombies: db1's root had used all 128 inotify instances — live processes of ~111 containers — so Alloy could not follow the journal; limit raised to 1024.) Cause on cpu1: healthcheck `wget https://hc.amf/…` with `timeout: 5s` while `wget --timeout=10` → the killed wget leaves `ssl_client` to Grafana |

### Status 2026-11-12

- **Docker log limit applied without downtime on cpu1, cpu2, gpu1, prod4** (they have `live-restore: true`):
  `deploy/logs/docker-log-limit.sh --apply` → `json-file` + `max-size 100m, max-file 5, compress true`;
  containers before = after on every host, logs/metrics verified. Backups: `/root/docker-config-backups/`.
  Applies to containers created/recreated from now on.
- **Recreated 2026-11-12 to apply the limit (old logs deleted, 24.5 GB freed)** with
  `deploy/logs/recreate-for-log-limit.sh <container> --apply` (same compose project/files/service as
  before, read from the container labels): dockprom `alertmanager` on cpu2 (5.3 GB), prod4 (5.3),
  cpu1 (3.8), gpu1 (2.0); `filebeat` prod4 (3.4), cpu1 (0.6); `gitlab-runner` prod4 (1.8);
  `promtail` cpu1 (1.7); `nginx-prometheus-exporter` cpu1 (0.6). All targets up, promtail ships.
- **Still unlimited, big logs — owners decide when to recreate**: prod4 `prod4.production.mongo.amf`
  **60.7 GB**, gpu1 `nginx-proxy` **11.0 GB** (would help gpu1's full `/`; ~5 s outage of its sites),
  prod4 `prod4.staging.marketdata.ch.amf` 5.9, prod4 `redis-staging-prod4` 4.6 (crash-looping), cpu1
  `mongo_raw` 1.9, cpu1/cpu2/gpu1 `*.dev.ch.amf` 0.7–1.5, `sidekick` 1.1–1.3, cpu1 `nginx-proxy` 1.3, …
  The rest pick the limit up at their next update (Watchtower).
- **For dockprom's owner:** its Alertmanager cannot deliver to Slack (`Notify for alerts failed …
  slack … unrecoverable error`) and logged that for every alert — that is why its logs were 2–5 GB.
- **2026-11-13 correction:** db1 **has** `live-restore: true` (an earlier truncated read said no) → it can
  get the limit like cpu1/cpu2/gpu1/prod4. **prod3 already has a limit** (`log-driver json-file`,
  `max-size 512m, max-file 2`) → nothing to do. Only **db2** lacks live-restore.
  `docker-log-limit.sh` now (a) checks that the **running** dockerd has live-restore (`docker info`),
  not just daemon.json, and refuses otherwise; (b) has `--enable-live-restore`: adds it and **reloads**
  dockerd (SIGHUP, no restart; refuses on a Swarm node). Rehearsed in Docker-in-Docker: containers kept
  running with unchanged start time.
- **Postponed (superseded by the correction above): db1, db2, prod3** (no `live-restore` → a Docker restart stops every container). Possible
  **without downtime in two steps**: (1) add `"live-restore": true` and `systemctl reload docker`
  (live-restore is reloadable, containers untouched), (2) then run `docker-log-limit.sh --apply`.
  Check first: not a Swarm node (`docker info -f '{{.Swarm.LocalNodeState}}'` = `inactive`; live-restore
  does not work with Swarm — maybe why it is off there). Caveat: during the ~5–10 s dockerd restart,
  chatty containers (db1: nginx-proxy, gitlab-ee) may block briefly on a full stdout pipe. The script
  would need that first step added (Swarm check → enable live-restore by reload → log limit).

### What to change

1. **Docker log limit** — `/etc/docker/daemon.json` (keep every existing key, add):

   ```json
   "log-opts": { "max-size": "100m", "max-file": "5" }
   ```

   = at most 500 MB per container. Docker cannot limit by age; Loki keeps 30 days of every container anyway.
   - needs `sudo systemctl restart docker`. **db1, db2, prod3 have no `live-restore` → ALL containers stop for ~1 min** (window!). cpu1, cpu2, gpu1, prod4 have `live-restore: true` → containers keep running.
   - applies only to containers **created afterwards**; existing ones keep their unlimited log (and its old content) until recreated (`docker compose up -d --force-recreate`, or Watchtower updates).
   - check first: `sudo docker info -f '{{.LoggingDriver}}'` = `json-file`; validate the edited file with `python3 -m json.tool /etc/docker/daemon.json`; backup the original.
2. **`init: true`** on the services that collect zombies (find them: `ps -eo ppid=,stat= | awk '$2~/^Z/{print $1}' | sort | uniq -c | sort -rn | head`, then `cat /proc/<ppid>/cgroup` → container id → `docker ps --no-trunc | grep <id>`). Add `init: true` to that service in its compose (override) file, then `docker compose up -d --no-deps <service>` (recreates it; data in named volumes stays).
   - cpu1 dockprom Grafana: script ready, **not run, could not be reproduced locally**: `deploy/services/dockprom-grafana-init.sh` (backup, adds one line under `  grafana:` in `/srv/docker/dockprom/docker-compose.override.yaml`, recreates only grafana, prints rollback).
   - optional: also fix that healthcheck's timeouts (`timeout:` ≥ wget's `--timeout × tries`).
3. **Order per host**: back up `daemon.json` → edit → `systemctl restart docker` → recreate the zombie containers with `init: true` (picks up the log limit at the same time) → check `docker ps` (all up), zombies (`ps -eo stat= | grep -c ^Z`), Alloy logs in Grafana.

### After the window

- run `deploy/logs/local-log-retention.sh --apply` on the hosts not done yet (see Changes 2026-11-11)
- verify in Grafana that every host still ships logs (Explore → Loki → `{host="<host>"}`)

## Changes 2026-11-16

- **Redis git (Rudolf's request): reviewed + pushed.** db1 `infrastructure/db1` main: `da53087`
  redis-staging TLS via haproxy (Ramsundar, 11-15), `0ff8986` our Redis 8 loadmodule fix (11-13); db2
  `infrastructure/db2` master: `d60d612` redis-staging TLS. Pre-commit secret scans clean; `redis.conf`,
  `tls/*.pem`, `data/` are gitignored; `*.bak-20261115` left untracked. Before: staging healthy (prod4
  master + 2 replicas, 3 sentinels). Not tracked: **prod4** (`/srv` has no git) has the same change.

- **Decision: no log policy on the ORIGINAL trading/portfolio logs on prod1 and prod3** — nothing of ours
  may delete or cap them; Loki keeps collecting (its copy expires after 30 days, the originals stay).
  State found: prod1 = QuantOffice files (StrategyServer, strategy + **audit** logs, Ember, TimeBase), Alloy
  only reads them; prod3 = Docker logs only (no trading units in the journal, nothing in `/var/log`);
  prod3's Docker `512m × 2` was there before us and is not ours; in Loki only the prod3 trading sidekicks.
  Made explicit (tested): `docker-log-limit.sh` exits on prod3; `recreate-for-log-limit.sh` skips
  trading/portfolio containers on prod3; `local-log-retention.sh` never deletes paths with
  trading/portfolio; comment in `prod1.alloy`. Old copies of these scripts on the hosts lack the guards —
  copy the new ones before using them again.
- **Decision: no local size limit for trading/portfolio on prod3** (prod1 has none already; prod3's
  journal stays 90 days). prod3's Docker default `512m × 2` (not ours) stays for everything else; the
  trading services get their own setting — **for the trading owner** (takes effect on their next deploy;
  Watchtower is off for them). Compose files: `/srv/docker/trading-{production,gsind-production,
  nexdos-production}/docker-compose.yml`; all services there use the anchor `x-trading-container`
  (labels `logging: "promtail"`; nexdos already has `logging: driver: "json-file"`). Add to the anchor:
  `logging: {driver: json-file, options: {max-size: "1000g", max-file: "1"}}`.
  Tested in a throwaway Docker with daemon `512m × 2`: no options / driver only → still 512m × 2;
  `max-size` `-1`, `""`, `0` → accepted at create but the container **fails to start** ("invalid size");
  `1000g` + `max-file 1` → starts, effectively unlimited. Open: confirm which services use the anchor
  (redis/sidekick may not).
- **prod3 trading logs in Loki:** `trading-production` and `trading-gsind-production` (portfolio-*,
  strategy-*-production / -GSIND_PROD) arrive via **promtail** (labels `container`, `logstream`, no `host`
  → missing from per-host counts). **`trading-nexdos-production`: no stream in Loki in 30 days** — not
  running, silent, or promtail does not pick it up → ask the owner.

## Changes 2026-11-14

- **db1 nginx-proxy recreated** (`recreate-for-log-limit.sh nginx-proxy --apply`, Saturday ~12:34):
  31.2 GB log deleted, nothing held it open (no filebeat restart needed); Prometheus
  `node_filesystem_avail_bytes{host="db1",mountpoint="/data"}` +31.2 GB. Baseline of the 46 sites behind
  db1's proxy (from the cert names in `/srv/docker/proxy/*.crt` resolving to 10.10.10.20) taken before:
  13× 200, 26× 30x, 4× 401, 3× 403 — identical after the recreate.
- **prod4 `sidekick-GSIND_PAPER_TRADING` (1.1 GB) + `sidekick` (trading-paper, 0.7 GB) recreated** 12:36
  (Saturday, markets closed). Before: Loki showed only health checks through them for 72 h (no S3 traffic).
  After: both `200 OK` to db1/db2 MinIO, `sidekick-pinger-paper` pinged healthchecks OK at 12:37. The
  `PYTHONPATH not set` compose warnings concern other services in those files (not recreated).
  → the "after hours" list is done; only owner recreates remain (≈ 330 GB).
- **prod4 filebeat held 21 deleted Docker logs** (the 2 sidekicks + logs of the 11-12/13 prod4
  recreates, which were counted as freed but were not) → `docker restart filebeat` 12:40 → 0 held,
  prod4 `/` **+9.2 GB** (Prometheus). Watch: if the held count grows again between restarts, filebeat
  also holds Docker's normal 100 MB rotations → its owner needs `close_removed`/`close_inactive`.
  Check per host: `sudo find /proc -mindepth 3 -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname '*json.log*(deleted)'`.
- **filebeat check on cpu1 and prod3:** cpu1 0 held. **prod3: filebeat held 32 deleted files, 2.4 GB** —
  nothing was recreated on prod3, so these are Docker's normal rotations (512m × 2) → filebeat holds
  rotated logs by itself, on every filebeat host (db1, cpu1, gpu1, prod3, prod4). `docker restart filebeat`
  → 0 held. Real fix for filebeat's owner: `close_removed: true` + `close_inactive: 5m` in its inputs.
- **Sentry on db1: `nginx` (5.3 GB), `worker` (1.1 GB), `snuba-sessions-consumer` (1.1 GB) recreated**
  (decision changed, with the go-ahead): images unchanged, 0 MB inside, 7.5 GB freed, filebeat holds 0.
  Afterwards `sentry.amf` 302 (as in the baseline), `/_health/` ok, nginx serving 200s, no errors in
  the 3 containers' logs.
- **ClickHouse dev (cpu1/cpu2/gpu1) and the other Sentry containers: left to the owners** (decision 11-14). Dry run on db1:
  only `nginx` 5.3 GB, `worker` 1.1 GB, `snuba-sessions-consumer` 1.1 GB are worth it (all 0 MB inside
  the container, no `.env.custom`); the other 14 Sentry containers < 0.1 GB. ClickHouse dev names:
  `<host>.dev.ch.amf`, `.dev.chproxy.amf`, `.dev.keeper.amf` (keepers on cpu1/cpu2/gpu1 = probably one
  3-node quorum → one at a time); not dry-run yet.
- **`recreate-for-log-limit.sh` got two safety checks** (tested locally): skips a container with > 200 MB
  written inside it (lost by a recreate; `ALLOW_RW=1` overrides), and one whose image would change
  (compares image IDs: changed tag or re-pulled `:latest`). First version of the image check was wrong on
  db1 (its older compose ignores the service in `config --images <svc>` → compared with another service's
  image, skipped safely); fixed to read the service's image from `config --format json`.

## Changes 2026-11-13

- **Retention check (read-only, port 3100):** central Loki holds logs back to 2026-10-14 (30 days);
  older already deleted by the 30-day retention. Decision: **stay at 30 days** centrally; locally journal
  + `/var/log` up to 90 days (cpu2 still pending), Docker logs size-limited only (100m × 5).
- **db1 Loki data volume — DONE 16:21** (`deploy/loki/add-loki-volume.sh --apply`, with the go-ahead):
  flush 1 s, `/loki` was 60 MB (copy: `/root/loki-data-backup-2026-11-13-162108`), ready after 40 s,
  check window 158163 → 158163, volume `grafana-loki_loki_data` on `/loki`, new container has the
  100m × 5 log limit, old 28 GB log deleted and not held open (on `/data` = Docker data-root, not `/`).
  Afterwards all 9 hosts + promtail streams arriving. Compose backup:
  `/root/loki-config-backups/docker-compose.yaml.2026-11-13-162107`. Rehearsal details below.
- (rehearsal) **db1 Loki data volume** (`deploy/loki/add-loki-volume.sh`).
  db1's Loki keeps `/loki` (WAL, not-yet-uploaded index, compactor) inside the container; chunks are in
  MinIO. Rehearsal (`loki-rehearsal/`, same image/config, `db1-like/` = db1's compose layout):
  recreate without flush → 200/200 recent lines **lost** (with a WAL, Loki does not flush on shutdown);
  `/flush` alone + recreate → OK only if nothing arrives in between (db1 always receives) →
  use `POST /ingester/shutdown?flush=true&terminate=false` (flushes, then refuses writes; clients retry);
  a clean stop uploads the index itself (stop timeout 120 s). Script under a nonstop writer: 1075/1075
  and 873/873 lines, check window 297/297 and 291/291, `grafana` in the same file untouched, named
  volume owned by 10001 (no chown). With the volume, a later recreate or `docker kill` without flush lost
  nothing (532/532). Loki refuses writes ≈ 20 s in the rehearsal (db1: flush time unknown, printed).

- **prod1 (10.10.10.11, Windows, RDP only) live** — same as prod2: `gen_windows.py prod1 10.10.10.11` →
  `install-alloy-prod1.ps1`; passwords written from a temporary `env.txt` (lengths checked 30/30,
  file deleted). Host-alive check on db1 added, dashboards: prod1 = prod2's red, **dashed** (palette has
  8 hues; no 9th colour), "Hosts sending" expects 9. Verified: 9/9 hosts, host-alive up, no alerts.
  **Finding for prod1's owner:** port 12345 is reachable from the whole LAN although the installer's
  firewall rule allows db1 only (on prod2 it is blocked) → Windows firewall on prod1 probably off or an
  allow-all rule. Only `/-/ready` + `/metrics` are open (UI needs login).
- **Windows event logs → Loki for prod1 and prod2** (`deploy/alloy/windows/config.alloy`): System (all
  levels) + Application (Critical/Error/Warning), one JSON line per event, labels `host job="windows"
  channel level`; level mapped from the level NUMBER to the Linux journal names (`crit err warning info
  debug` — German Windows would otherwise give "Fehler"/"Warnung"; the text stays in the line as
  `levelText`); same redaction; bookmarks in Alloy's data folder (starts with current events, no
  history). Installer now also stores `LOKI_PASSWORD` and reads passwords from an `env.txt` next to the
  script (deleted automatically). Verified 2026-11-13: both hosts ship, metrics unchanged.
  Search: `{job="windows"}`, `{host="prod1", level="err"}`.
- authentik: group `Grafana Admins` now has parent `Grafana Users` (admins no longer need both groups);
  `deploy/db1/grafana/INSTALL.md` corrected (only `Grafana Users` is bound to the application).
- **prod1 QuantOffice monitoring (handover from the QuantOffice side, `deploy/alloy/windows/handover-prod1-2026-11-13/`):**
  merged into our Windows Alloy instead of replacing it (`windows/prod1.alloy`, appended for prod1 only;
  `process` collector in `windows/config.alloy`). Logs → Loki: `job=strategyserver`, `job=ember`
  (`service=` from the path), `job=timebase` — multiline, timestamps from the line (UTC), levels mapped to
  crit/err/warning/info/debug, secrets redacted, no backfill (`ignore_older_than 2h`). Metrics:
  `windows_process_*` for TimeBase/StrategyServer/java (TimeBaseSvcLauncher handles ≈ 260k),
  `job=timebase-jvm` (JMX exporter, live after Saturday; exempt from ExporterDown until then).
- **Two Redis crash loops fixed (unnoticed for months):**
  prod4 `redis-staging-prod4` — image 7.2 could not read the RDB v12 snapshot from the 7.4 master
  (db2) → upgraded to `redis-stack-server:7.4.0-v8` like db1/db2 (`deploy/services/fix-redis-staging-prod4.sh`;
  last loadable snapshot was ~160 days old). db1 `redis` (Redis 8.10.3, /srv/docker/redis) — the image
  loads its bundled modules itself and CONFIG REWRITE had written them into redis.conf as well → loaded
  twice → "server aborting"; fixed with an entrypoint wrapper that drops the `loadmodule` lines before each
  start (`deploy/services/fix-redis8-db1.sh`). The redis8 sentinels (db1/prod3/prod4) stopped their
  endless failover attempts. Both instances are back in the Redis targets → `RedisDown` covers them.
- **For the owner of /srv/docker/redis (Redis 8, db1:36379): it has NO password** — PING works
  unauthenticated from the LAN (TLS, no client cert). Set requirepass/ACL, then rerun
  `fill-redis-env.sh` on db1. Is this redis8 group still used at all? Also: its compose healthcheck runs
  `redis-cli ping` without TLS (shows unhealthy); prod4 staging Redis runs with `--loglevel debug`
  (now effective with the 7.4 image: ~17k log lines/day).
- `fill-redis-env.sh` fixed: it only checked the PING reply, so a password found in a config file but not
  active in Redis counted as "ok"; now AUTH must say OK, and "no password set" is reported as a WARNING.
- **Recreates for the log limit, 2026-11-13:** db1 alertmanager/filebeat/promtail/healthchecks/sidekick,
  db2 alertmanager/scaphandre/prometheus/sidekick, cpu1/cpu2/gpu1 sidekick, cpu2/prod4 scaphandre+prometheus,
  gpu1/prod4 promtail, gpu1 nginx-proxy (11.2 GB, all 6 gpu1 sites answered identically before/after).
  ≈ 44.8 GB freed today (+ 24.5 GB on 11-12 = 69.3 GB in total). **filebeat keeps deleted Docker log files open** → on gpu1 the
  space only came back after `docker compose restart filebeat` (+14 GB; gpu1 `/` 31 → 45 GB); checked db1,
  db2, cpu1, cpu2, prod4: nothing held. **scaphandre** (dockprom) on db2/cpu2/prod4 stopped answering after
  its recreate (was already erroring 300×/h with no metrics for ≥ 1 day) → ExporterDown firing; decision open.
  Zombie counts: db1 ~142k, **db2 ~172k** processes (init: true topic).
- **Docker log limit done on db1 and db2** (`docker-log-limit.sh`): db1 113→113 containers; db2 first
  `--enable-live-restore` (reload, 89/89 untouched), then the limit. **Side effect on db2:** the dockerd
  restart started 4 *stopped* containers with `restart: always` (Docker starts those on a daemon
  restart): `snp_analyst_etl` (waited for Vault — could have run an old ETL), `identifier_mappings`,
  `identifier_mappings_v10`, `refinitiv_indicative_data_etl_v4_5` (Dagster code locations crashing:
  `DagsterUserCodeLoadError`). Stopped again right away (`docker stop`, state as before). Lesson: before
  a dockerd restart, list stopped containers with restart policy always —
  `docker ps -a --filter status=exited --format '{{.Names}}' | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' | grep always`.
  On db1/cpu1/cpu2/gpu1/prod4 the counts were equal before/after.
- Redis logs: all Redis containers are collected; production/trading Redis just had no log line since
  late October (Redis logs only on events). Their `REDIS_ARGS=--loglevel debug` is ignored by the
  plain `redis` image.

## Changes 2026-11-12

- **Docker log limit on cpu1, cpu2, gpu1, prod4** (live-restore hosts, no downtime) and 9 containers
  recreated to apply it (24.5 GB of old logs deleted) — details in the maintenance-window section above.
- **cpu1 overload** (load ~1,150 on 64 cores, ssh timing out) from parallel jobs/agent sessions of
  `aha`, `rgo`, `ade` — not this work. Per-user CPU fairness proposed (see 2026-11-11). cpu1 dockprom
  Grafana restarted: 246,482 zombie processes cleared (they come back without `init: true`).
- **Full disks found on cpu2/gpu1** via `HostDiskAlmostFull` + cAdvisor (`container_fs_usage_bytes`):
  the conda containers, not the logs (open item 1).
- **Grafana MCP for Claude Code** (local tooling on the Mac, not in this repo): `mcp-grafana` (Homebrew)
  registered as user-scope MCP server `grafana`, wrapper `~/.claude/mcp-grafana-amf.sh` — read-only
  (`--disable-write --disable-admin`), Amfileon CA, token read from `AMF_GRAFANA_TOKEN` in `~/.zshrc` at
  start (never in a config file).
- Grafana service account behind `AMF_GRAFANA_TOKEN` temporarily given **Admin** (2026-11-13, to read
  the user list) — set it back to Viewer when no longer needed.

## Changes 2026-11-11 — logs (Loki)

- **Loki on db1 (existing `/srv/docker/grafana-loki`, Loki 2.9.10, S3 = MinIO `db1.s3.amf`) keeps 30 days**
  (`deploy/loki/enable-loki-retention.sh 30`; first 90, changed the same day — approved by the boss).
  The compactor deletes older chunks incl. the old promtail logs.
- **Alloy ships logs from all 7 Linux hosts** (`deploy/alloy/config/logs.alloy`): every container
  (via read-only `docker-socket-proxy`, wollomatic, GET list/inspect/logs/networks/events only) + the
  systemd journal; secrets redacted; skipped: `logging=promtail` containers (promtail still ships them)
  and vault/infisical/yopass/shhh. Only the last 24 h were shipped on first start (no backfill —
  decided: Loki fills to 30 days by itself by ~2026-12-11; `deploy/logs/backfill-loki.py` exists if
  one service's history is ever needed). Alloy capped at 2 cores (`cpus: 2.0`).
- Loki datasource **Loki** (`uid loki-db1`) in grafana.amf; users `alloy`/`grafana` in nginx's
  htpasswd for `db1.loki.amf`. Guide: `deploy/loki/INSTALL.md`.
- **Local logs on the servers: 90 days** — `deploy/logs/local-log-retention.sh` (journal
  `MaxRetentionSec=90day`, rotated `/var/log` files > 90 d, glusterfs via its own logrotate rule,
  inotify limit 1024). **Applied on db1 only.** Still to run (dry run, then `--apply`):
  db2, cpu1, cpu2, gpu1, prod3, prod4 — on prod3/prod4 it installs logrotate (missing there; their
  3.4 GB glusterfs logs were never rotated). Docker logs: see the maintenance window above.
- db1: root had used all 128 inotify instances → Alloy's journal reader stalled silently from 17:50
  UTC; fixed by the limit raise + Alloy restart (19:44 UTC).
- Open, small: journal label `syslog_identifier` (messages without a unit are text-search only);
  prod1/prod2 Windows event logs — done 2026-11-13; retire promtail on each host once Alloy also ships the
  `logging=promtail` containers; Loki: add a data volume (WAL is in the container), upgrade 2.9 → 3.x.
- cpu1 overload 2026-11-11 from 19:00 CET (load ~1,150 on 64 cores, ssh timing out): many parallel
  jobs/agent sessions of `aha`, `rgo`, `ade` — **not** related to this work. Proposal for the team:
  per-user CPU fairness via `/etc/systemd/system/user-.slice.d/50-fair-cpu.conf`
  (`CPUWeight=100`, `CPUQuota=2400%`, `TasksMax=4096`).

## Changes 2026-11-04

- **prod2 (10.10.10.12, Windows, RDP only — no ssh) live**: Alloy as Windows service, built-in Windows
  exporter, core metrics renamed to node-exporter names (job `nodeexporter`) so prod2 appears in Fleet/Host
  detail and the host alerts; drives C: D: E: Q: as `fstype="ntfs"`. Installer: `deploy/alloy/windows/`
  (`gen_windows.py prod2 10.10.10.12` → `install-alloy-prod2.ps1`, run as Administrator over RDP).
  Passwords in `C:\ProgramData\Amfileon\alloy` (SYSTEM + Administratoren only); firewall: 12345 from db1 only.
  Lessons: German Windows → use SIDs (`*S-1-5-32-544`) not group names; pasting into a hidden prompt over
  RDP can drop characters → check stored length (30).
- Alert emails: "View In Alertmanager" → Grafana Monitoring dashboard; every alert has a `dashboard` link.

## Changes 2026-11-01

- **Grafana SSO with authentik live**: application `Grafana AMF` (slug `grafana-amf`), roles via application
  entitlements `Grafana Admins` → Admin / `Grafana Viewers` → Viewer, login restricted to groups
  `Grafana Admins` / `Grafana Users`. Details: `deploy/db1/grafana/INSTALL.md`.
- For authentik's owner: the LDAP source reports "Configuration error" on every sync; update 2026.8.5 available.

## Changes 2026-10-29

- **ClickHouse live**: 5 production + 2 staging servers, metrics switched on **without restart** (config
  reload). Keepers not switched on (need a restart; only the Keeper table uses them). Not covered:
  `db2.staging.marketdata.ch.amf` and `db2.production.marketdata.keeper.amf` (no Docker network).
- **Certificate checks moved to cpu2** (all 92 names incl. grafana.amf). Reason: db1's Alloy joined
  proxy_network and the ClickHouse networks, where Docker's DNS answers container names
  (db1.production.ch.amf, gitlab.amf, …) — 5 **false** CertificateCheckFailed from 2026-10-28 ~15:50
  until 2026-10-29 12:00 (emails went out). Rule: never run the certificate checks on an Alloy that
  joins service networks.
- `install-on-host.sh` now always recreates Alloy/Grafana (`up -d` alone ignores changed config files).
- Grafana on db1 sends mail (invites, password reset) via Alertmanager's SMTP account.

## Security findings that predate this work — report to the service owners

These services were set up by others and are **not changed by this work**; the fixes below are
recommendations for their owners.

| Finding | Risk | Suggested fix |
|---|---|---|
| **Loki on db1 (`:3100`) is open on the whole LAN without a login** | Anyone on the LAN/VPN can read the strategy and ETL container logs | Stop publishing 3100 on `0.0.0.0` (bind to localhost/an internal network), or put it behind nginx-proxy with TLS + auth; promtail clients then push via that endpoint |
| **dockprom Grafana config on db1 is world-readable and contains passwords**: `grafana.ini` (Office 365 SMTP password of `system@amfileon.com`) and `ldap.toml` (LDAP bind password), both `root:root 644` | Any user with a login on db1 can read them | `chmod 600` both (Grafana runs as root in dockprom, or use `chown 472`), better: move the values into `.env` / `GF_*` variables; consider rotating both passwords |
| dockprom's Grafana on db1 sends usage stats to Grafana Labs | Data leaving the network | `grafana.ini`: `[analytics] reporting_enabled = false`, `check_for_updates = false`, `check_for_plugin_updates = false` |
| Exporters published on the LAN without auth: postgres-exporter db1/db2 (`:9187`, `:9188`), nvidia-dcgm gpu1 (`:9400`), scaphandre (random ports) | Database names/activity and host details readable by anyone on the LAN | Alloy now reads them inside Docker, so remove their `ports:` from dockprom's override files |
| Old copy of the Amfileon CA on db1 and gpu1 (`/srv/docker/proxy/CA.pem`, `amfileon-ca.crt`) expires **2032-07** | Anything verifying against that file fails after 2032 (same key as the renewed 2036 copy) | Replace with the renewed CA file (as on db2/cpu2) |
| 27 names with a certificate file + DNS record but no matching vhost (nginx-proxy serves its default certificate) | Stale entries; clients get a certificate error | Listed at the end of `deploy/alloy/certificate-targets.txt` — remove or fix |
| `.env` files of other services are readable by normal users (2026-10-29/30: 96 of 109 on db1, db2, cpu1, cpu2, gpu1, prod3; 9 of 10 on prod4). Almost all logins on prod4 are in the `docker` group | Secrets readable by every login; docker group members can reach them anyway | Owners' decision, **not changed by this work** (decided 2026-10-30): `root:root 600` means `docker compose` needs sudo; shrink the `docker` group |
| `/home` on db1 (97 %) and cpu1 (93 %) almost full | Writes there fail at 100 % | Real `HostDiskAlmostFull` alerts — clean up / extend |
| **Read-only replicated tables in ClickHouse** (found 2026-10-29): db1.production 3, db2.production 3, prod3.production 1, db2.staging 1 — despite a working Keeper session | Inserts into these tables fail | **Cause found 2026-11-05: empty test tables** (`default.demo`, `demo2`, `demo_rudi` on db1/db2 production; `demo_rudi_test` on prod3; `perf_test_replicated_db1_primary` on db2 staging; 0 rows, created Nov 2025) with no metadata in Keeper. Rudi to `DROP TABLE … SYNC` them; the `ClickHouseReadonlyReplica` alerts then clear |
| **`preview.dagster.amf` certificate check failing** since at least 2026-11-11 (no proper certificate served) | `CertificateCheckFailed` keeps firing | Dagster's owner: fix the vhost/certificate, or remove the name from `deploy/alloy/certificate-targets.txt` if the preview is gone |
| **cpu1: Grafana admin password in plaintext** in `/srv/docker/dockprom/docker-compose.override.yaml` (`GF_SECURITY_ADMIN_PASSWORD`), file `644`. It was also shown once in a Claude session on 2026-11-11 | Every login on cpu1 can read the admin password of `grafana.cpu1.amf` | **Rotate it**, move it to dockprom's `.env` (`600`) |
| **promtail configs world-readable with the Loki password** (`/srv/docker/promtail/promtail-config.yaml`, `644`, on db1, cpu1, cpu2, gpu1, prod3, prod4) | Every login can push to / read from Loki as `promtail` | `chmod 600` (promtail runs as root), or retire promtail (Alloy has its own login) |

## Ideas, not decided

| Idea | Decision needed |
|---|---|
| **Network flows** (who talks to whom, bytes per source/destination) via Alloy's eBPF/Beyla module | Privileged Alloy on each host; test in `local-rehearsal/` first |
| **Web endpoints** per `*.amf` site / client / status code from nginx-proxy access logs (as metrics) | Access to nginx-proxy's logs (root-only today) or an extra log file |
| Suggest to dockprom's owner: its per-host Prometheus/Grafana/Alertmanager are now redundant (its cAdvisor is the biggest CPU user on db2) | Owner's decision — dockprom is not touched by this work |
| **Make our setup independent of dockprom (dockprom itself stays untouched).** Today Alloy scrapes dockprom's exporters (node-exporter, cAdvisor, nginx, scaphandre, postgres, nvidia, pushgateway) over dockprom's `monitor-net`; stopping dockprom stops those metrics (ExporterDown fires), and a host without dockprom (e.g. prod4) can't use the current Alloy setup. Alloy's built-in `prometheus.exporter.unix` / `.cadvisor` / `.postgres` could replace most of them, leaving only GPU/nginx/scaphandre as separate exporters | **Paused 2026-10-26 — current setup kept as is.** Rehearsal so far (`phase2-rehearsal/`, `compare.py`): built-in node-exporter = full parity (all 11 node metrics, labels, values); built-in cAdvisor = network OK, per-container CPU/memory missing — likely needs `/sys:/sys:ro` mounted (untested). Cost: a second cAdvisor per host |
