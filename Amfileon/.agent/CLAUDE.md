# CLAUDE.md — Amfileon (.agent)

Project-specific knowledge for the Amfileon on-prem servers. The repo-root `CLAUDE.md` holds the
commit/PR conventions; this file holds infrastructure facts and points at the per-project skills.

## Project facts

| Surface | Value |
|---|---|
| Servers in scope | db1 10.10.10.20 · db2 10.10.10.21 · cpu1 .30 · cpu2 .31 · gpu1 .40 · prod3 .13 (prod4 .14: no access yet) |
| Access | `ssh <host>` as `ssa`, port 22022 — **only with the VPN connected** |
| OS | Ubuntu 22.04 (db2: 24.04), x86_64; ufw active on every host |
| Services | Docker Compose projects under `/srv/docker/<service>/`, all `root:root` (dirs 755, files 644) |
| Ingress | `nginx-proxy` + docker-gen on every host (`VIRTUAL_HOST`), network `proxy_network` |
| TLS | Internal "Amfileon CA" (`/srv/docker/proxy/CA.pem`); per-name certs `<name>.crt/.key` next to it. Two CA files with different fingerprints exist — same key, one is a renewal; both verify. |
| Monitoring (2026-10) | dockprom on every host (isolated islands) → being replaced by Alloy → Prometheus db1 + db2; see `prometheus_alloy_monitoring/` |
| Postgres HA | Patroni/etcd/vip-manager on db1/db2/prod3, VIP 10.10.10.18; see `postgres_cluster/` |
| Secrets | `.env` per service; committed twins are `.env.example` / `*.sanitized` (see `srv_version_control/`) |

## Per-project skills (in `.agent/skills/`)

| Skill | Purpose |
|---|---|
| `howto_server_changes` | How Claude may (and may not) touch the servers: read-only ssh, no sudo/docker, staging via scp, secrets in `.env` never read, final permission lockdown of new `/srv/docker` services |
