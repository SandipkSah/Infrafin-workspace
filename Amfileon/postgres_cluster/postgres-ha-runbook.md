# Postgres HA Cluster — Primary + Hot Standby Runbook

**Goal (from ticket "Postgres cluster", 2026-07-07):**
> WAL replication, one writer OK (no multiple writers) → hot standby

One primary accepting writes, one or more **hot standbys** (streaming WAL, open for read-only queries).
**No multi-master.** The only real design question is therefore **how failover happens**, not how
replication works — every option below uses the same stock Postgres WAL streaming underneath.

> ✅ **STATUS 2026-07-17: THE CLUSTER IS LIVE AND DRILL-TESTED on db1+db2.** Two-node
> Spilo/Patroni cluster, VIP-routed, full failover drill passed on real hardware (promotion,
> VIP migration across the switches, fencing, rejoin). See **AS-BUILT** below for what runs
> where, the drill evidence, the findings, and the one remaining gap. Phases 0–6 and 8 of this
> runbook were executed (Phase 7 backups/monitoring still pending); the phase sections are kept
> as the how-it-was-done reference.

---

## AS-BUILT (2026-07-17) — what is actually running

**Deploy dirs:** `/srv/docker/pg-cluster-instance-1/` on db1, `/srv/docker/pg-cluster-instance-2/`
on db2 (per-node numbering). Repo copies: `postgres_cluster/deploy/{db1,db2}/docker-compose.yaml`
(the `docker-compose.local.yaml` files are the Mac rehearsal variants).

| Component | Host | State |
|---|---|---|
| Spilo (Postgres 17.2 + Patroni 4.x), member **db1** | db1 `10.10.10.20:15432` | ✅ live — Replica or Leader per etcd |
| Spilo, member **db2** | db2 `10.10.10.21:15432` | ✅ live |
| **Interim plaintext etcd** (single member `pg-etcd-db2`) | db2 `:12379` | ✅ live — **the cluster's DCS today** |
| vip-manager 4.2.0 (self-built image) | db1 + db2 | ✅ live — VIP `10.10.10.18` follows the leader key |
| Patroni REST | both `:18008` | ✅ live |
| Shared mTLS etcd (etcd1 db1 / etcd2 db2, `patroni-etcd-1`) | `:2379` | ⏸ running but **UNUSED** — blocked for Patroni (cert EKU, below); etcd3/prod3 still down |
| `postgres:13` + `postgres-develop` (standalone, pre-existing) | db2 | ⚠️ untouched; PG13 is EOL — separate task |

**Key facts** (each one was discovered the hard way — don't rediscover them):
- **Ports** follow the pre-provisioned ufw "prepend-1" scheme: **15432** Postgres, **18008** REST,
  **12379/12380** interim etcd. Both hosts had the rules pre-created and labeled.
- **Interfaces differ per host:** db1 = `ens259f0`, db2 = `ens259f0np0`. Always verify with
  `ip route get 10.10.10.1`.
- **Member names = host hostnames** (`db1`, `db2`) because of host networking — vip-manager's
  `trigger-value` must match.
- `.env` (PG passwords) must be **byte-identical** on both nodes.
- `PGPORT` env is set alongside `SPILO_CONFIGURATION` so Spilo's side tools (pgqd) use 15432.

### Drill evidence (2026-07-17, real hardware)
`docker compose stop pg2` on db2 → lease expired (~30s) → **db1 promoted** (timeline bump) →
db1's vip-manager (WATCH on the leader key) raised **10.10.10.18 on ens259f0**, gratuitous ARP
crossed the real switches → `psql host=10.10.10.18` from an off-segment Mac hit the new writable
primary → db2's vip-manager **fenced** (removed the VIP on its side) → `start pg2` → db2
**rejoined as Replica, streaming, lag 0**, same timeline. Also verified earlier on db2 alone:
restart-recovery (vip-manager drops the VIP until leadership is re-confirmed, then re-raises).
Verification gotcha: `inet_server_addr()` over the VIP returns the VIP itself — use
`psql ... -c "select pg_read_file('/etc/hostname')"` to prove which host answered.

### 🔴 Finding: etcd server certs block the mTLS path (root-caused)
Patroni ↔ shared etcd fails: `remote error: tls: bad certificate` on `/v3/*` while `/version`
works with the same client certs. Cause (proven): **etcd server certs carry EKU `serverAuth`
only**; etcd's embedded JSON gRPC-gateway (which Patroni speaks to) self-dials the gRPC server
presenting the *server* cert as its client credential — rejected under `client-cert-auth=true`.
**Fix: reissue etcd server certs with EKU `serverAuth,clientAuth`** (same SANs; CA owner has the
key — requested). vip-manager is unaffected (native gRPC). Diagnostic signature to remember:
*/version works, /v3 fails ⇒ EKU problem.* Until the reissue, the cluster runs on the interim
plaintext etcd; the mTLS config is kept as commented blocks in both compose files (the switch
is: swap the marked env blocks, re-add the certs mount, `chown 101:103` the client key — Patroni
runs as uid 101 and can't read a 0600-root key).

### Failure tolerance today — one red row
| What dies | Result |
|---|---|
| pg container on either node | ✅ auto-failover (drill-proven) |
| db1 host | ✅ db2 side keeps the referee; no action |
| **db2 host** | ❌ the single interim etcd dies with it → db1 **cannot** self-promote → manual procedure below |
| interim etcd container only | ⚠️ both Patronis lose DCS → primary demotes read-only until it's restarted (auto via `restart: always`) |

**Interim emergency procedure (db2 host dead):** on db1: `docker compose exec pg1 patronictl list`
will fail (no DCS) — bring up a temporary etcd (or wait for db2), or as last resort promote
manually: `docker compose exec pg1 bash -c 'pg_ctl promote -D /home/postgres/pgdata/pgroot/data'`
and raise the VIP by hand (`ip addr add 10.10.10.18/24 dev ens259f0`). **Document any manual
promotion immediately — the old db2 data dir must then be rewound/reinitialized before rejoining.**

**Closes with:** 3-member etcd across db1/db2/prod3 (access to prod3 requested). Growth procedure:
`etcdctl member add` FIRST, then start the joiner with `--initial-cluster-state existing` and a
full member list — one member at a time (a registered-but-unreachable member still counts toward
quorum). Then update `ETCD3_HOSTS` / `VIP_DCS_ENDPOINTS` on both nodes.

### Other operational findings
- **vip-manager has no official Docker image** (ghcr: denied; Docker Hub: 404). Image is self-built
  from the official v4.2.0 release binary — `deploy/db2/vip-manager/Dockerfile`. Env names that
  differ from folklore: `VIP_NETMASK` (not VIP_MASK), `VIP_DCS_ENDPOINTS` (not VIP_ETCD_ENDPOINTS).
  The release tarball also contains `vip-manager.yml` — extract by **exact name** or a wildcard
  nondeterministically installs the YAML as the "binary" (bit db1). The `--version` build guard
  catches this. Base image needs `iproute2` (the `ip` binary it execs) + `iputils-arping` (GARP).
  TODO: push the built image to `registry.amf` so hosts stop rebuilding.
- **Docker Hub mirrors are unreliable:** `registry.git.amf` / `dockerhub-mirror.amf` intermittently
  serve inconsistent manifests (`unexpected commit digest`, different pair each retry). Remedy:
  `docker builder prune -f && docker pull <base>`; report to the mirror owner. Long-term: mirror
  bases into `registry.amf`.
- Spilo v4 ignores the legacy admin-user envs (*"User creation is not supported starting from
  v4.0.0"*) — create app users via SQL/post_bootstrap.

### Remaining work
1. **etcd 1→3** across db1/db2/prod3 (needs prod3 access) — closes the red row.
2. **Cert reissue** (dual-EKU) → switch both nodes + vip-managers to the shared mTLS etcd.
3. **Phase 7:** pgBackRest/WAL-G → MinIO (a replica is NOT a backup) + repoint postgres-exporter,
   alerts (replication lag, inactive slots, DCS health, primaries ≠ 1).
4. `postgres.amf` DNS → `10.10.10.18` at `10.10.10.1`, then client migration — pending the still-open
   question of **what workload this cluster serves** (new DB vs. replacing the EOL `postgres:13`).
5. Mirror Spilo + vip-manager images into `registry.amf`, digest-pinned.

---

## The alternatives (answers the ticket's bullets 2 & 3)

All four give one writer + hot standby. They differ **only** in who decides to fail over.

| Approach | Failover | Extra components to operate | Verdict for Amfileon |
|---|---|---|---|
| **Plain streaming replication** | Manual (human runs `pg_ctl promote`) | none | Safest, simplest. RTO = time to wake someone. |
| **repmgr** (Bitnami images) | Automatic | none (nodes vote among themselves) | Simpler than Patroni, but 2-node split-brain protection is easy to get subtly wrong. |
| **pg_auto_failover** | Automatic | a *monitor* node | Good middle ground — correct semantics, no etcd to run. |
| **⭐ Patroni + etcd + VIP** | Automatic | etcd ×3 + vip-manager | Heaviest — **but the etcd half already exists here.** Industry standard. |

**Recommendation: Patroni.** Not because it's the lightest — it isn't — but because the expensive part
(a 3-member mTLS etcd cluster) is **already built and already running here**. Switching to
pg_auto_failover now would mean *discarding* working infrastructure to save operating something that's
already running. The marginal cost of Patroni from here is the Patroni config + the VIP layer.

**Routing decision (settled): a Virtual IP driven by vip-manager — no proxy.** Clients connect to a
single name `postgres.amf` → a floating VIP that always sits on the current primary. Chosen over
HAProxy because it needs **zero client change** (one stable name forever) and is lighter than running
a proxy that itself needs HA. See Phase 6. Clients only ever hit the primary; the standby is for
redundancy, not read-scaling.

*(If the etcd work turns out to be exploratory and can be binned, pg_auto_failover is the lower-
complexity answer and this recommendation flips. **Confirm before building** — see Open Questions.)*

### Components needed (answers bullet 2)

1. **Postgres nodes** — primary + hot standby(s), WAL streaming.
2. **Patroni** — one agent per node, **bundled in the same container as Postgres** (it must run
   `pg_ctl promote` / `pg_basebackup` locally; it cannot be a sidecar).
3. **etcd ×3** — the DCS. Holds the leader lease. *Exists (degraded).*
4. **VIP + vip-manager** — connection routing. A floating IP (`postgres.amf`) that vip-manager keeps on
   whichever node holds the etcd leader key. Apps must **never** hardcode a node's real IP — they use
   the VIP. `nginx-proxy` **cannot** route this (it routes HTTP by `VIRTUAL_HOST`; Postgres is raw TCP).
5. **pgBackRest / WAL-G** — backups. **A replica is not a backup** — it faithfully replicates your
   `DROP TABLE`. Target: the existing MinIO/S3 on db2.
6. **postgres-exporter → Prometheus** — *already running*, just repoint.

---

## Target topology

```
                    ┌──────────── etcd (the referee, quorum 2/3) ────────────┐
                    │  etcd1 db1:.20   etcd2 db2:.21   etcd3 prod3:.13       │
                    └────▲────────▲──────────▲────────▲───────────▲──────────┘
                         │ leader │          │ leader │           │
                  reads  │  key   │   reads  │  key   │           │
              ┌──────────┴──┬─────┘   ┌──────┴─────┬──┘           │
              │ vip-manager │         │ vip-manager│              │
              │ Patroni:8008│         │Patroni:8008│              │
              │ Postgres5432│         │Postgres5432│              │
              │  PRIMARY    │─────────│  REPLICA   │  ← WAL streaming
              │  db1 (.20)  │         │  db2 (.21) │
              └──────▲──────┘         └────────────┘
                     │ VIP 10.10.10.18 lives here (on the primary)
                     │  ▲ moves to db2 on failover (gratuitous ARP)
          ┌──────────┴───────────┐
          │  postgres.amf → VIP  │  ← apps connect HERE (one name, forever)
          └──────────────────────┘
```

Patroni agents **never** talk to each other — every decision goes through etcd. That is what makes
split-brain structurally impossible: a node stranded by a network partition cannot write to a majority,
so it cannot claim the leader key, so it demotes itself. **vip-manager rides the exact same leader
key**: the VIP follows the key, so promotion and routing are driven by one source of truth and cannot
disagree.

---

## Phase 0 — Rehearse on your own machine (DO THIS FIRST)

Never learn Patroni on a host running the firm's production trading stack. Build a throwaway 3-node
cluster locally, kill the primary, watch the promotion. ~30 min, zero risk.

```bash
git clone https://github.com/patroni/patroni
cd patroni
docker compose up -d          # ships a working local etcd + 3× Patroni/Postgres + HAProxy
docker compose exec patroni1 patronictl -c /etc/patroni.yml list
```

**Drill:** `docker compose stop patroni1`, then re-run `patronictl list` every few seconds. Watch the
leader lease expire (TTL 30s) and a replica promote itself. **That's the whole product.** Then restart
patroni1 and watch it rejoin as a replica.

**Exit criteria:** you can explain, unprompted, why the demoted node did not become a second primary.

---

## Phase 1 — Restore etcd quorum (prod3) — BLOCKING

Nothing else should be built until the referee has real fault tolerance.

**First, decide it's acceptable.** etcd on prod3 means an fsync-heavy, disk-latency-sensitive process on
a **production trading box**, and it puts prod3 in the failure path of the database cluster. It's likely
the only way to get a 3rd voter from the hosts available — but that must be a *conscious* decision, not
an inherited one. **This is an open question for the ticket owner, not a decision for you.**

Then, on prod3 (`10.10.10.13`):

```bash
ls -la /srv/docker/patroni/ 2>/dev/null || echo "(never deployed)"
docker ps -a | grep -i etcd
```

- **If a compose file + certs are already there, unstarted** → `docker compose up -d`, done.
- **If prod3 was never touched** → replicate `/srv/docker/patroni/` from db2, changing `ETCD_NAME=etcd3`,
  the two `ADVERTISE` URLs to `10.10.10.13`, the volume to `etcd3_data`, and the certs to `etcd3.*`.
  **The certs must be issued from the same internal `amf` CA** (`ca.crt`) — the internal CA owner holds it.

> ⚠️ `ETCD_INITIAL_CLUSTER_STATE=new` is correct only when bootstrapping a *fresh* cluster. The cluster
> **already exists**, so etcd3 joins as an **existing** member. Set `ETCD_INITIAL_CLUSTER_STATE=existing`
> and register it first with `etcdctl member add`. Getting this wrong can fork the cluster.

**Verify (from db2) — quorum must show 3/3 and one leader:**
```bash
E="--endpoints=https://10.10.10.21:2379 --cacert=/certs/ca.crt \
   --cert=/certs/etcd2.client.crt --key=/certs/etcd2.client.key"
docker exec patroni-etcd-1 etcdctl $E member list -w table
docker exec patroni-etcd-1 etcdctl $E endpoint status --cluster -w table   # exactly one IS LEADER=true
docker exec patroni-etcd-1 etcdctl $E endpoint health --cluster
```

**Exit criteria:** 3 members, all healthy, one leader, no `failed to reach peer` in the logs.

---

## Phase 2 — Build the Postgres + Patroni image

Patroni and Postgres **ship in one container** (Patroni is PID 1 and spawns Postgres as a child).

**Option A — Spilo (Zalando's prebuilt: Postgres + Patroni + WAL-G):**
```yaml
image: ghcr.io/zalando/spilo-17:4.0-p2      # tag format: spilo-<pgversion>:<spilo-version>
```

**Option B — DIY (more transparent; easier to explain in review):**
```dockerfile
FROM postgres:17
RUN apt-get update && apt-get install -y python3-pip python3-psycopg2 \
 && pip3 install --break-system-packages "patroni[etcd3]" \
 && rm -rf /var/lib/apt/lists/*
COPY patroni.yml /etc/patroni.yml
USER postgres
ENTRYPOINT ["patroni", "/etc/patroni.yml"]     # Patroni is PID 1, NOT postgres
```

Push to `registry.amf/data/…` and **pin the tag** (no `:latest` — `watchtower` is running on db2 and
will happily restart things under you).

---

## Phase 3 — `patroni.yml` (per node)

This is db2's copy; db1's differs only in `name`, the `connect_address`es, and the cert filenames.

```yaml
scope: amfcluster                    # → keys land under /service/amfcluster/ in etcd
name: pg2                            # this node's identity

restapi:
  listen: 0.0.0.0:8008               # Patroni REST API (health/role); not client-facing with a VIP
  connect_address: 10.10.10.21:8008

etcd3:                               # note: etcd3 = the v3 API, NOT the third member
  hosts:
    - 10.10.10.20:2379               # db1
    - 10.10.10.21:2379               # db2
    - 10.10.10.13:2379               # prod3
  protocol: https
  cacert: /certs/ca.crt
  cert:   /certs/etcd2.client.crt    # ← the client cert already generated
  key:    /certs/etcd2.client.key

bootstrap:
  dcs:
    ttl: 30                          # leader lease lifetime  ─┐ these two numbers
    loop_wait: 10                    # heartbeat interval     ─┘ ARE your failover time
    retry_timeout: 10
    maximum_lag_on_failover: 1048576 # refuse to promote a replica >1MB behind
    postgresql:
      use_pg_rewind: true            # lets a demoted ex-primary rejoin without a full rebuild
      parameters:
        wal_level: replica
        hot_standby: "on"            # ← the ticket's requirement, literally this line
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.10.10.21:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    superuser:   {username: postgres,   password: "${PG_SUPERUSER_PASSWORD}"}
    replication: {username: replicator, password: "${PG_REPLICATION_PASSWORD}"}
  pg_hba:
    - hostssl replication replicator 10.10.10.0/24 scram-sha-256
    - hostssl all         all        10.10.10.0/24 scram-sha-256
    # NO 0.0.0.0/0. NO trust.
```

Secrets → `.env`, quoted, **never** in the compose file (same lesson as the registry migration).
Generate real passwords (`openssl rand -base64 32`) — do not repeat the `registry_password` mistake.

---

## Phase 4 — Bootstrap the primary (db1)

```bash
cd /srv/docker/postgres-ha && docker compose up -d      # db1 only
docker compose logs -f patroni     # expect: "no leader, acquiring initial leader lock" → "promoted"
```

**Verify:**
```bash
docker compose exec patroni patronictl -c /etc/patroni.yml list
#   Member  Host          Role     State     TL  Lag
#   pg1     10.10.10.20   Leader   running    1

# the leader key now exists in etcd — this is the referee's answer:
docker exec patroni-etcd-1 etcdctl $E get --prefix /service/amfcluster/ --keys-only
```

**Exit criteria:** exactly one Leader, `running`, and `/service/amfcluster/leader` present in etcd.

---

## Phase 5 — Add the hot standby (db2)

Start db2's node with the **same `scope`**, a different `name` (`pg2`), and an **empty data dir**.
Patroni sees a leader already holds the lock, so it does **not** promote — it runs `pg_basebackup`
from db1 and begins streaming WAL. No manual replication setup at all.

```bash
docker compose up -d && docker compose logs -f patroni   # expect: "bootstrapping from leader pg1"
docker compose exec patroni patronictl -c /etc/patroni.yml list
#   pg1  10.10.10.20  Leader   running    1
#   pg2  10.10.10.21  Replica  streaming  1   0
```

**Verify replication is real, from the primary:**
```sql
SELECT client_addr, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```
**Verify hot standby is actually readable** (the ticket's literal requirement) — on db2:
```sql
SELECT pg_is_in_recovery();     -- must be TRUE
SELECT count(*) FROM <sometable>;   -- must succeed (read)
CREATE TABLE t(i int);              -- must FAIL: "cannot execute in a read-only transaction"
```
That last failure is the **success** condition — it proves "one writer, no multiple writers".

---

## Phase 6 — VIP + vip-manager (connection routing) — NOT OPTIONAL

Without this, failover promotes a new primary that **no application can find**. This is the most
commonly skipped component and the one that makes the whole exercise pointless if omitted.

**Design:** a spare IP `10.10.10.18` is the **VIP**. DNS `postgres.amf` → `10.10.10.18`, static and
forever. The VIP physically sits on whichever node is currently primary. `vip-manager` (one per
Postgres node) reads the **etcd leader key** — the same key Patroni uses — and:
- if *this* node holds the leader key → raise the VIP on the local NIC + announce it (gratuitous ARP);
- if it does not → make sure the VIP is **down** locally.

One source of truth (the leader key) drives both promotion and the VIP, so they cannot disagree, and
the VIP cannot land on two nodes at once (etcd guarantees one key holder). **Use vip-manager, NOT bare
keepalived** — keepalived runs its own VRRP election on "is the node up", which is a *different*
question from "is this node the Postgres primary", and the two can disagree. vip-manager has no
election of its own; it just obeys etcd.

### How the VIP actually moves — gratuitous ARP (the mechanism)

**The MAC addresses never change.** db1's NIC is always `aa:aa:aa…`, db2's is always `bb:bb:bb…`. What
moves is the **mapping** of the VIP to a MAC.

- Normal L2 delivery: the switch forwards by MAC, and clients cache an IP→MAC mapping (ARP cache) for
  minutes. Initially every client caches `10.10.10.18 → aa:aa:aa` (db1), and traffic to the VIP lands
  on db1.
- Failover: Patroni promotes db2; db2's vip-manager runs `ip addr add 10.10.10.18/24 dev eth0`. db2 now
  holds the address — **but every client's ARP cache still says `…50 → aa:aa:aa` (the dead node).**
- Fix — **gratuitous ARP**: db2 broadcasts, unprompted, *"10.10.10.18 is at bb:bb:bb"*. Every device
  overwrites its cache to `…50 → bb:bb:bb`; the switch already knows `bb:bb:bb` is on db2's port. New
  traffic to the VIP now lands on db2. Sub-second, no DNS change, no client reconfigured.
- vip-manager fires **several** gratuitous ARPs (not one) in case a broadcast is missed.

> ⚠️ **Network prerequisite:** all nodes must share one L2 subnet (`10.10.10.0/24` ✅), and the switch
> must **permit gratuitous ARP**. Managed switches with **Dynamic ARP Inspection (DAI)** may block it
> (a gratuitous ARP looks like ARP spoofing). If DAI is on, the VIP silently won't move. **Confirm with
> whoever runs the network gear before relying on this.**

### Deployment — vip-manager as a host-networked sidecar (per Postgres node)

vip-manager **must run on every node that can become primary** (db1 + db2) — it manipulates that node's
own interface, so it can't run anywhere else. **Not on prod3** (etcd-only, never runs Postgres). It
runs on the replica too, sitting idle until that node is promoted.

Deployed as a container **consistent with the rest of the stack** (everything on these hosts is Compose).
A plain container has its own network namespace, so `ip addr add` would touch a virtual interface the
switch never sees — hence `network_mode: host` + `NET_ADMIN`:

```yaml
# add to the per-node Patroni compose file (this is db1's; db2 sets trigger-value: pg2)
services:
  vip-manager:
    image: ghcr.io/cybertec-postgresql/vip-manager:v2.6.0   # PIN the tag (watchtower is live)
    network_mode: host          # use the HOST net namespace so ip-add hits the real eth0
    cap_add: [NET_ADMIN]        # allow adding/removing IPs + sending gratuitous ARP
    restart: always
    volumes:
      - ./vip-manager.yml:/etc/vip-manager/vip-manager.yml:ro
      - ./certs:/certs:ro       # SAME etcd client certs Patroni uses
```

`vip-manager.yml` (db1's copy — db2 differs only in `trigger-value`):

```yaml
vip:        10.10.10.18            # the spare IP postgres.amf points to
mask:       24
interface:  eth0
trigger-key:   "/service/amfcluster/leader"
trigger-value: "pg1"              # raise the VIP when leader key == this node (db2: "pg2")
dcs-type:      etcd
dcs-endpoints:
  - https://10.10.10.20:2379
  - https://10.10.10.21:2379
  - https://10.10.10.13:2379
etcd-ca-file:   /certs/ca.crt
etcd-cert-file: /certs/etcd2.client.crt
etcd-key-file:  /certs/etcd2.client.key
```
> Verify the exact config keys against the vip-manager v2 docs before shipping — key names have shifted
> across versions; the shape above is correct but confirm spelling.

### Checklist before enabling

- [ ] A **spare, unused IP** on `10.10.10.0/24` reserved for the VIP (`.50`?) — not in any DHCP range,
      not assigned to anything. Confirm with `ping`/`arping` that nothing answers.
- [ ] DNS at `10.10.10.1`: `postgres.amf A 10.10.10.18`.
- [ ] Gratuitous ARP permitted on the switch (DAI check above).
- [ ] Postgres container publishes 5432 on the host (`0.0.0.0:5432`) **or** runs `network_mode: host`,
      so traffic to `VIP:5432` actually reaches Postgres. Don't bind Postgres to a single fixed IP that
      isn't the VIP.
- [ ] Clients use `postgres.amf` and **reconnect on error** — the VIP re-resolves instantly, but an app
      holding a broken connection to the old primary must retry. Confirm Dagster/ETL pools reconnect.

### Verify

```bash
# on the current primary — VIP should be present:
ip addr show eth0 | grep 10.10.10.18
# on the replica — VIP should be ABSENT
# from anywhere:
psql "host=postgres.amf user=postgres" -c "SELECT pg_is_in_recovery();"   # → f (it's the primary)
```

---

## Phase 7 — Backups and monitoring

**Backups (pgBackRest → the existing MinIO/S3 on db2):** full + WAL archiving, off-box.
**A replica is not a backup.** Schedule a **restore drill** — an untested backup is a rumour.
Include a PITR-to-timestamp test.

**Monitoring** — `postgres-exporter`, Prometheus, Grafana and Alertmanager are **already running on
db2**. Repoint the exporter and alert on:

- **replication lag** (bytes + seconds)
- **replication slot growth** — 🔴 an inactive slot silently fills the primary's disk and takes it
  down. This is the classic Patroni-cluster outage. Alert on it.
- etcd quorum / member count < 3
- number of primaries **≠ 1** (should be structurally impossible — alert anyway)
- connection saturation, long-running transactions

---

## Phase 8 — Failover drill (the only proof that any of this works)

**Planned (zero data loss):**
```bash
patronictl -c /etc/patroni.yml switchover --candidate pg2
```
**Unplanned — do this too, it exercises a different code path:**
```bash
docker compose stop patroni     # on the primary; simulates the 03:00 power cable
# watch three things move together:
#   1. lease expires (≤30s) → replica promotes    patronictl list
#   2. leader key flips to pg2                     etcdctl get /service/amfcluster/leader
#   3. VIP moves to db2 (gratuitous ARP)           ip addr show eth0 | grep 10.10.10.18
```
**Watch the VIP specifically** — run `ip addr` on both nodes and confirm `10.10.10.18` disappears from
db1 and appears on db2, and that `psql host=postgres.amf` now lands on the new primary.
**Time it.** That number is your RTO and it's what will be asked for.
Then restart the old primary and confirm it rejoins **as a replica** (`use_pg_rewind` earns its keep)
and that its vip-manager keeps the VIP **down** (it no longer holds the leader key).

---

## Rollback

Patroni is **additive** — it does not touch the existing `postgres:13` / `postgres-develop` containers.
At any point before pointing `postgres.amf` at the VIP and cutting applications over:

```bash
cd /srv/docker/pg-cluster-instance-1 && docker compose down    # on db1
cd /srv/docker/pg-cluster-instance-2 && docker compose down    # on db2 (also stops the interim etcd)
```
The old standalone Postgres is untouched and still serving. vip-manager removes the VIP on graceful
shutdown. Add `-v` only if you also intend to destroy the cluster's data (pg volumes + interim etcd
volume). The shared mTLS etcd (`/srv/docker/patroni/`) is a separate deployment — leave it alone;
**do not delete its volumes**, they are the future DCS.

---

## Open questions — status after the 2026-07-17 build

Resolved by building and testing:
- ~~Patroni vs alternatives~~ → **Patroni + Spilo deployed and drill-proven.**
- ~~Which spare IP~~ → **VIP = `10.10.10.18`** (arping-verified free before use).
- ~~Is gratuitous ARP permitted on the switches?~~ → **Yes — empirically proven**: the VIP moved
  db2→db1 during the drill and an off-segment client followed it within seconds. No DAI blocking.
- ~~Routing~~ → VIP + vip-manager, live on both nodes.

### 🔴 Still open (for the ticket owner)

1. **What is this cluster actually FOR?** New database, or replacement for the EOL `postgres:13`
   on db2? This gates DNS cutover (`postgres.amf` → 10.10.10.18) and client migration.
2. **prod3 as the 3rd etcd voter** — access requested. It puts an fsync-heavy process on a prod
   trading box and prod3 into the DB's failure path; it's also the only 3rd failure domain
   available (cpu1/cpu2 are alternatives if access is easier). Until it lands, **db2's host is
   write-mandatory** (see the red row in AS-BUILT).
3. **Cert reissue** (etcd server certs with EKU `serverAuth,clientAuth`) — requested from the CA
   owner. Gates the switch from interim plaintext etcd to the shared mTLS cluster.
4. **RTO / data-loss tolerance:** failover is async-replication based — a failover can lose the
   last seconds of commits. If that's unacceptable for the eventual workload, Patroni's
   `synchronous_mode` is the knob (cost: writes block if the standby is down). Nobody has stated
   an RPO yet — ask before real workload lands.
5. **Backups (Phase 7) are not built.** A replica is not a backup. Do not put irreplaceable data
   on this cluster until pgBackRest/WAL-G + a restore drill exist.

---

## Appendix — quick reference

```bash
# etcd health (from db2)
E="--endpoints=https://10.10.10.21:2379 --cacert=/certs/ca.crt \
   --cert=/certs/etcd2.client.crt --key=/certs/etcd2.client.key"
docker exec patroni-etcd-1 etcdctl $E endpoint status --cluster -w table
docker exec patroni-etcd-1 etcdctl $E get --prefix /service/ --keys-only

# cluster state
patronictl -c /etc/patroni.yml list
patronictl -c /etc/patroni.yml history          # past failovers
patronictl -c /etc/patroni.yml switchover       # planned, zero data loss
patronictl -c /etc/patroni.yml reinit pg2       # rebuild a hopeless replica from scratch

# replication, from the primary
SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;
# 🔴 inactive slots — the silent disk-filler
SELECT slot_name, active, pg_size_pretty(
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```

**Glossary:** **DCS** = Distributed Configuration Store (etcd) — the referee holding the leader lease.
**Quorum** = a strict majority; without it a node cannot write, so it cannot claim leadership, so it
cannot split-brain. **Hot standby** = a replica open for read-only queries. **TTL/lease** = the
dead-man's switch; the primary must keep renewing it or etcd deletes it and a replica takes over.

---

## References — verify every claim in this runbook

Everything above is checkable. Primary sources only; no blog posts.

### Patroni
- **Docs (start here):** https://patroni.readthedocs.io/
- **Source / README:** https://github.com/patroni/patroni — *"A template for PostgreSQL High Availability
  with Etcd, Consul, ZooKeeper, or Kubernetes"*. MIT. Supports PG 9.3–18.
- **Full `patroni.yml` reference** (every key in Phase 3): https://patroni.readthedocs.io/en/latest/yaml_configuration.html
- **REST API** (`GET /primary`, `GET /replica` — role/health endpoints): https://patroni.readthedocs.io/en/latest/rest_api.html
- **`patronictl`** (`list`, `switchover`, `failover`, `reinit`): https://patroni.readthedocs.io/en/latest/patronictl.html
- **Replication modes** (async vs sync — relevant to "can we lose data on failover?"):
  https://patroni.readthedocs.io/en/latest/replication_modes.html
- **Local Compose demo:** the `docker-compose.yml` in the repo root — this is what Phase 0 runs.

### VIP / connection routing (Phase 6)
- **vip-manager (Cybertec)** — the tool that follows the etcd leader key: https://github.com/cybertec-postgresql/vip-manager
- **Patroni "why not a proxy" / VIP discussion** (callbacks + `on_role_change`): https://patroni.readthedocs.io/en/latest/existing_data.html and the docs' HA/architecture notes
- **Gratuitous ARP** (the L2 mechanism the VIP move relies on): RFC 5227 (IPv4 Address Conflict Detection) / RFC 826 (ARP)

### etcd
- **Docs:** https://etcd.io/docs/v3.5/
- **FAQ — why an odd number of members / what quorum buys you:** https://etcd.io/docs/v3.5/faq/
  (has the failure-tolerance table: 3 members tolerate 1 failure, 5 tolerate 2)
- **🔴 Runtime reconfiguration — the Phase 1 procedure:** https://etcd.io/docs/v3.5/op-guide/runtime-configuration/
  **Verified 2026-07-14.** Confirms: `etcdctl member add` **first**, then start the new member with
  `ETCD_INITIAL_CLUSTER_STATE=existing` and a cluster list that **includes itself**. Explicit warning:
  a misconfigured new member *"is counted in the quorum even if that member is not reachable"* — i.e.
  botching etcd3 can take down the currently-working 2-member cluster. Add members one at a time.
- **Security / mTLS** (what the `CLIENT_CERT_AUTH=true` + certs are doing):
  https://etcd.io/docs/v3.5/op-guide/security/

### PostgreSQL (the replication underneath all of it)
- **Hot standby** — the ticket's literal requirement: https://www.postgresql.org/docs/current/hot-standby.html
- **Streaming replication / warm standby:** https://www.postgresql.org/docs/current/warm-standby.html
- **`pg_stat_replication`** (the lag query in the appendix): https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW
- **Replication slots** (the silent disk-filler): https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS
- **🔴 Versioning / EOL policy:** https://www.postgresql.org/support/versioning/
  **Verified 2026-07-14: PostgreSQL 13 reached EOL on 13 November 2025** — no further security patches.
  Supported today: 14 (until Nov 2026), 15, 16, 17, 18. The `postgres:13` container on db2 is unsupported.

### Images
- **Spilo** (Postgres + Patroni + WAL-G, by the Patroni authors): https://github.com/zalando/spilo
  — *"Highly available elephant herd: HA PostgreSQL cluster using Docker"*. Images at
  `ghcr.io/zalando/spilo-<pgversion>`.

### The alternatives (for the comparison the ticket asks for)
- **pg_auto_failover:** https://pg-auto-failover.readthedocs.io/ (monitor node instead of etcd)
- **repmgr:** https://www.repmgr.org/
- **pgBackRest** (Phase 7 backups): https://pgbackrest.org/user-guide.html
