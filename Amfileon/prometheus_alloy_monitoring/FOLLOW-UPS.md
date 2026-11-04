# Monitoring rollout — open items

Status as of 2026-10-28. The new setup (Alloy on 6 hosts → Prometheus db1 + db2, alerting on db1,
dashboards in `grafana-local/`, certificate checks for 91 names with alerts) is live and verified. Everything below is still open.

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
| **Read-only replicated tables in ClickHouse** (found 2026-10-29): db1.production 3, db2.production 3, prod3.production 1, db2.staging 1 — despite a working Keeper session | Inserts into these tables fail | `SELECT database, table, zookeeper_exception FROM system.replicas WHERE is_readonly` on each server; `ClickHouseReadonlyReplica` alerts are firing (critical for production) |

## Ideas, not decided

| Idea | Decision needed |
|---|---|
| **Network flows** (who talks to whom, bytes per source/destination) via Alloy's eBPF/Beyla module | Privileged Alloy on each host; test in `local-rehearsal/` first |
| **Web endpoints** per `*.amf` site / client / status code from nginx-proxy access logs (as metrics) | Access to nginx-proxy's logs (root-only today) or an extra log file |
| Suggest to dockprom's owner: its per-host Prometheus/Grafana/Alertmanager are now redundant (its cAdvisor is the biggest CPU user on db2) | Owner's decision — dockprom is not touched by this work |
| **Make our setup independent of dockprom (dockprom itself stays untouched).** Today Alloy scrapes dockprom's exporters (node-exporter, cAdvisor, nginx, scaphandre, postgres, nvidia, pushgateway) over dockprom's `monitor-net`; stopping dockprom stops those metrics (ExporterDown fires), and a host without dockprom (e.g. prod4) can't use the current Alloy setup. Alloy's built-in `prometheus.exporter.unix` / `.cadvisor` / `.postgres` could replace most of them, leaving only GPU/nginx/scaphandre as separate exporters | **Paused 2026-10-26 — current setup kept as is.** Rehearsal so far (`phase2-rehearsal/`, `compare.py`): built-in node-exporter = full parity (all 11 node metrics, labels, values); built-in cAdvisor = network OK, per-container CPU/memory missing — likely needs `/sys:/sys:ro` mounted (untested). Cost: a second cAdvisor per host |
