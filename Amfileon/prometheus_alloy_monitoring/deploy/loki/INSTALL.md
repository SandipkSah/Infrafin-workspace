# Logs: Alloy → Loki on db1 → grafana.amf

One Loki (the existing `/srv/docker/grafana-loki` on db1, `https://db1.loki.amf`, S3 = MinIO
`db1.s3.amf`) receives the logs of every host; they are searched in **https://grafana.amf**
(Explore → datasource *Loki*), kept **30 days**.

| Source | How | Labels |
|---|---|---|
| all containers (except `logging=promtail` and vault/infisical/yopass/shhh) | Alloy `loki.source.docker` via a read-only Docker API proxy | `host job=docker container compose_project compose_service stream` |
| systemd journal | Alloy `loki.source.journal` (read-only mount) | `host job=journal unit level` |
| Windows event logs on prod1, prod2 (System all, Application Critical/Error/Warning) | Alloy `loki.source.windowsevent` (Windows service, `deploy/alloy/windows/`) | `host job=windows channel level` (level = crit/err/warning/info) |
| trading/ETL containers (`logging=promtail`) | promtail, as before (until it is retired) | `container logstream level …` |

Passwords, tokens, API keys, `Authorization` headers and `user:password@` in URLs are replaced by
`<redacted>` on the host. Lines older than 24 h are not shipped (Alloy's first start would
otherwise push each container's entire Docker log history).

## 1. Retention — done 2026-11-11 (30 days)

`enable-loki-retention.sh 30`: first set to 90 days, changed to 30 days the same day; the compactor deletes older chunks from S3.

## 2. Logins on db1.loki.amf (you, on db1)

Users `alloy` (push) and `grafana` (read) in nginx-proxy's `/srv/docker/proxy/htpasswd/db1.loki.amf`;
promtail's user stays. Only bcrypt hashes travel (`deploy/secrets/loki-htpasswd`, from `gen-secrets.sh`).

```bash
scp deploy/secrets/loki-htpasswd db1:loki-htpasswd
scp deploy/loki/add-loki-users.sh db1:
ssh -t db1 'bash ~/add-loki-users.sh'
```

## 3. Loki datasource in grafana.amf

```bash
deploy/stage.sh grafana-dashboards db1
ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'
```
Adds `GRAFANA_LOKI_PASSWORD` to db1's existing `.env` (other values untouched) and recreates Grafana.

## 4. Alloy collects logs — one host at a time (db1 first)

```bash
deploy/stage.sh alloy db1
ssh -t db1 'bash ~/install-alloy.sh alloy'
```
Adds `config/logs.alloy`, the `docker-socket-proxy` container (wollomatic/socket-proxy: only
GET list/inspect/logs/networks/events, everything else 403) and read-only journal mounts.
Metrics are unaffected. **Note:** `stage.sh alloy <host>` for *any* host now also starts log
collection there.

Rollback on a host: remove `config/logs.alloy` from `/srv/docker/alloy/config/` and
`sudo docker compose up -d --force-recreate --remove-orphans` (the proxy can stay; it does nothing alone).

## Rehearsal

`loki-rehearsal/` (Loki 2.9.10 + MinIO with db1's config) and `loki-rehearsal/alloy-logs/`
(the real `deploy/alloy/docker-compose.yaml` + `logs.alloy` against it):
```bash
cd loki-rehearsal && docker compose up -d && alloy-logs/compose.sh up -d
```
Tested 2026-11-11: retention (100/95-day logs deleted, 60/1/0-day kept), labels, redaction (no
secret through), promtail/vault containers excluded, 24 h cut-off, no duplicates after restart,
proxy refuses everything outside the allowlist.
