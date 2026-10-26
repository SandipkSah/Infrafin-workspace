# Monitoring rollout — open items

Status as of 2026-10-26. The new setup (Alloy on 6 hosts → Prometheus db1 + db2, alerting on db1,
dashboards in `grafana-local/`, certificate checks for 91 names with alerts) is live and verified. Everything below is still open.

## Pending steps of this rollout

| # | Item | Who | Notes |
|---|---|---|---|
| 1 | Watchdog heartbeat | ops | Create the healthchecks.io check (period 1 min, grace 5 min), run `deploy/fill-db1-env.sh`, restart alertmanager. **Until then nothing pages anyone if db1 itself dies.** |
| 2 | Alert recipient → team address | ops | `ALERT_EMAIL_TO` in db1 `/srv/docker/prometheus/.env`, then `sudo docker compose up -d alertmanager` |
| 3 | Dashboards into dockprom's Grafana on db1 | Claude prepares, ops installs | provision `grafana-local/dashboards/*.json` + the two datasources (see `deploy/README.md` step 5) |
| 4 | Commit to git | Claude | `deploy/secrets/` and `inventory/` stay git-ignored |
| 5 | **Final lockdown** of `/srv/docker/{prometheus,alloy}` on every host | ops (root) | `deploy/README.md` step 6 — must be the last step |
| 6 | prod4 | ops | no access yet; add to Alloy, host-alive and certificate lists once available |

## Security findings that predate this work (dockprom era)

| Finding | Risk | Suggested fix |
|---|---|---|
| **Loki on db1 (`:3100`) is open on the whole LAN without a login** | Anyone on the LAN/VPN can read the strategy and ETL container logs | Stop publishing 3100 on `0.0.0.0` (bind to localhost/an internal network), or put it behind nginx-proxy with TLS + auth; promtail clients then push via that endpoint |
| dockprom's Grafana on db1 sends usage stats to Grafana Labs | Data leaving the network | `grafana.ini`: `[analytics] reporting_enabled = false`, `check_for_updates = false`, `check_for_plugin_updates = false` |
| Exporters published on the LAN without auth: postgres-exporter db1/db2 (`:9187`, `:9188`), nvidia-dcgm gpu1 (`:9400`), scaphandre (random ports) | Database names/activity and host details readable by anyone on the LAN | Alloy now reads them inside Docker, so remove their `ports:` from dockprom's override files |
| Old copy of the Amfileon CA on db1 and gpu1 (`/srv/docker/proxy/CA.pem`, `amfileon-ca.crt`) expires **2032-07** | Anything verifying against that file fails after 2032 (same key as the renewed 2036 copy) | Replace with the renewed CA file (as on db2/cpu2) |
| 27 names with a certificate file + DNS record but no matching vhost (nginx-proxy serves its default certificate) | Stale entries; clients get a certificate error | Listed at the end of `deploy/alloy/certificate-targets.txt` — remove or fix |
| `/home` on db1 (97 %) and cpu1 (93 %) almost full | Writes there fail at 100 % | Real `HostDiskAlmostFull` alerts — clean up / extend |

## Ideas, not decided

| Idea | Decision needed |
|---|---|
| **Network flows** (who talks to whom, bytes per source/destination) via Alloy's eBPF/Beyla module | Privileged Alloy on each host; test in `local-rehearsal/` first |
| **Web endpoints** per `*.amf` site / client / status code from nginx-proxy access logs (as metrics) | Access to nginx-proxy's logs (root-only today) or an extra log file |
| Slim dockprom down to just its exporters (its per-host Prometheus/Grafana/Alertmanager are now redundant; its cAdvisor is the biggest CPU user on db2) | After the new setup has run for a while |
| **Remove the dependency on dockprom.** Today Alloy scrapes dockprom's exporters (node-exporter, cAdvisor, nginx, scaphandre, postgres, nvidia, pushgateway) over dockprom's `monitor-net`; stopping dockprom stops those metrics (ExporterDown fires), and a host without dockprom (e.g. prod4) can't use the current Alloy setup. Alloy's built-in `prometheus.exporter.unix` / `.cadvisor` / `.postgres` could replace most of them, leaving only GPU/nginx/scaphandre as separate exporters | Phase 2: run in parallel on one host, compare series, then switch host by host |
