# Postgres HA — per-host deployment (Spilo)

Real-world layout: **one directory per physical host**, each holding the compose file for what
runs *on that host*. Mirrors the `/srv/docker/<service>/` convention already used on the Amfileon
boxes.

```
deploy/
  db1/    etcd1 + Spilo(pg1, primary)  + vip-manager   → real host 10.10.10.20
  db2/    etcd2 + Spilo(pg2, replica)  + vip-manager   → real host 10.10.10.21
  prod3/  etcd3 only                                   → real host 10.10.10.13
```

## Image
`ghcr.io/zalando/spilo-17:4.0-p2` — Postgres 17 + Patroni 4.x + WAL-G, **multi-arch** (amd64 + arm64),
Apache-2.0. In production, **mirror this into `registry.amf` and pin the digest** (don't pull ghcr on
prod hosts; watchtower chases tags).

## Running the whole thing locally on one Mac (rungs 2–3 test)

The per-host compose files share ONE external Docker network so the three "hosts" can talk on this
laptop, resolving each other by container name (`etcd1`, `pg1`, …). On real hosts this is replaced by
the flat `10.10.10.0/24` L2 network — see PROD DELTA below.

> **File naming:** `docker-compose.local.yaml` = the **Mac local test** (shared bridge net, plaintext
> etcd) — every host has one. `docker-compose.yaml` = the **real per-host deploy** (what runs on the
> actual server). So far only db2 has its real deploy; db1/prod3 real files are written when we get there.

```bash
docker network create amf-ha           # the shared "LAN" for the local test
cd deploy
docker compose -f prod3/docker-compose.local.yaml up -d   # etcd3 first (any order really)
docker compose -f db1/docker-compose.local.yaml   up -d   # etcd1 + pg1
docker compose -f db2/docker-compose.local.yaml   up -d   # etcd2 + pg2
```

Tear down:
```bash
for h in db1 db2 prod3; do docker compose -f $h/docker-compose.local.yaml down -v; done
docker network rm amf-ha
```

## PROD DELTA — what changes for the real db1/db2/prod3

The local files are runnable-as-is on one Mac. For real deployment, per host:

1. **Image** → `registry.amf/data/spilo-17@sha256:…` (mirrored + digest-pinned).
2. **Networking** → drop the shared bridge; use `network_mode: host` (or the real `10.10.10.0/24`),
   and set every `*_HOSTS` / `connect_address` to real IPs (`10.10.10.20/21/13`), not container names.
3. **etcd = mTLS v3** → the local test uses **plaintext etcd with the v2 API enabled** (Spilo's
   `ETCD_HOSTS` speaks v2). Real etcd 3.5 has v2 **off** and requires client certs. On prod either:
   - point Spilo at etcd via **v3 + TLS** (`ETCD_CACERT`/`ETCD_CERT`/`ETCD_KEY`, and confirm Spilo
     emits an `etcd3:` block — verify the generated `/run/postgres.yml`), **or**
   - if staying on Spilo's `ETCD_HOSTS`, enable v2 on the etcd cluster.
   **This is the #1 integration item to nail on the real cluster.** ← flagged in the runbook.
4. **Secrets** → real values in each host's `.env` (here they're throwaway), ideally from Infisical.
5. **vip-manager** → enable the `vip` profile and give it `network_mode: host` + `NET_ADMIN` so it can
   raise the VIP `10.10.10.18` on the real NIC. It CANNOT function on Docker-for-Mac (no real L2), so
   it is profiled OFF for the local test — we watch the etcd leader key instead (its input).
```
