# Amfileon Monitoring HA Cluster — Proposal & Design

**Proposal — prepared 2026-10-07 · status: validated in local rehearsal 2026-10-12 (28/28 checks
pass, see [Rehearsal results](#rehearsal-results--2026-10-12)); not yet deployed to servers**

Turns the current single-host dockprom stack on db1 into a two-node, highly available Prometheus /
Alertmanager / Grafana cluster, validated first in a local container rehearsal before touching any
server.

---

## Why this exists

Today every metric, dashboard and alert for the Amfileon hosts lives in one dockprom stack on db1.
If db1's disk fails, its Docker daemon hangs, or someone reboots it, three things happen at once:
metrics stop being collected, dashboards go dark, and — worst — **alerts stop firing**, so nobody is
told that anything is wrong. The monitoring system fails silently at exactly the moment it is needed.

This proposal removes that single point of failure. Two independent collectors watch every host, a
query layer stitches their data into one view, and the alerting path survives the loss of either node.

---

## What dockprom gives us — and what it doesn't

[`stefanprodan/dockprom`](https://github.com/stefanprodan/dockprom) is an original project (not a
fork), created 2016, actively maintained. It is a well-built **single-host** stack: Prometheus,
Alertmanager, Grafana, node-exporter, cAdvisor, Pushgateway and Caddy on one Docker bridge network.
Its README and compose file contain nothing about clustering, replication, remote storage or multiple
hosts.

| dockprom as shipped | Why it blocks HA |
|---|---|
| `container_name:` fixed on every service | Only one copy of each service can exist |
| Single `monitor-net` bridge network | Services can only reach each other on the same host |
| Scrape targets `nodeexporter:9100`, `cadvisor:8080` | Only monitors the host it runs on |
| `prometheus_data` local volume, `200h` retention | One copy of the metrics; lose the disk, lose the data |
| `external_labels: monitor: 'docker-host-alpha'` | No `replica` label, so two copies can't be de-duplicated |
| `grafana_data` local volume (SQLite) | Grafana state lives on one disk |
| Alertmanager without `--cluster.*` flags | One instance; no peer to take over |
| Caddy as the only entry point | One front door on one host |

**What we keep from dockprom unchanged:** the exporter definitions, `alert.rules`, the Alertmanager
receiver config, and the provisioned Grafana dashboards. The work is in the topology, not the content.

---

## Key facts that shape the design

These answer the questions in the original ticket.

**Prometheus does not replicate.** There is no leader/follower mode and no mechanism to sync one
Prometheus's data to another. The standard HA pattern is to run **two identical Prometheus instances
that scrape the same targets independently**. Each holds a full, independent copy of the data.

**Prometheus is therefore not HA on its own.** HA comes from a query layer in front of the pair.
We use **Thanos**: a sidecar next to each Prometheus exposes its data, and **Thanos Query** reads from
both, merges them and removes duplicates using a `replica` label. If one Prometheus is down, queries
are answered by the other; when it returns, any gap in its data is filled from its peer at query time.

**Alertmanager *does* cluster natively.** Instances gossip over port 9094 and share silences and
notification state, so two Alertmanagers receiving the same alert send **one** notification, not two.

**Grafana reaches the cluster through Thanos Query.** Thanos Query speaks the Prometheus HTTP API, so
in Grafana it is an ordinary "Prometheus" datasource pointed at `thanos-query` instead of
`prometheus`. Each Grafana uses the Thanos Query on its own node.

**Grafana is active/passive behind one address, and stateless.** Both nodes run an identical Grafana
built entirely from provisioning files in git — datasources and dashboards — so there is no state
to share between them. A floating IP (keepalived) sits on whichever node has a healthy Grafana.
Users have one URL; if a node dies the address moves to the other Grafana, which already shows the
same dashboards. Users log in again once (sessions are per node); nothing else changes.

### What is replicated, and how

| Component | State | HA mechanism |
|---|---|---|
| Prometheus TSDB | metrics | **Not synced.** Both scrape the same targets; Thanos de-duplicates at query time |
| Prometheus config + alert rules | files | Git — identical on both nodes except the `replica` label |
| Alertmanager | silences, notification log | Native gossip cluster |
| Grafana | datasources + dashboards | Provisioning files in git, loaded by both nodes; read-only in the UI |
| Grafana | login sessions | **Not shared.** Per-node SQLite; users re-login after a failover |
| Grafana entry point | one user-facing address | Floating IP via keepalived, follows a healthy Grafana |
| Long-term metrics *(optional follow-up)* | 2h TSDB blocks | Thanos sidecar uploads to MinIO |

---

## Topology

db1 and db2 each run a complete monitoring node. Every host — including db1 and db2 themselves —
runs the two exporters. Either node alone can collect, query, alert and display.

```
                         ┌─────────────────────────────────┐
                         │            Users                 │
                         │  grafana.amf → <GRAFANA VIP>     │
                         └────────────────┬────────────────┘
                                          │ keepalived (VRRP)
                    (moves here if db1    │ (normally sits here)
                     Grafana is unhealthy)│
                    ┌─────────────────────┴─────────┐
                    ▼                               ▼
              db2 · grafana                   db1 · grafana
                    ▲                               ▲
                    └──── same provisioning ────────┘
                          files from git
                          (no shared state)

     ┌──────────────── exporters on every host ────────────────┐
     │  db1   db2   prod3   cpu1   cpu2   gpu1                 │
     │  node-exporter :9100      cadvisor :8080                 │
     └──────────────┬───────────────────────────┬──────────────┘
          scrape all│                           │scrape all
                    ▼                           ▼
┌──────────────────────────────────┐ ┌──────────────────────────────────┐
│ db1 · 10.10.10.20  (node A)       │ │ db2 · 10.10.10.21  (node B)       │
│ ──────────────────────────────── │ │ ──────────────────────────────── │
│ prometheus     replica="db1"     │ │ prometheus     replica="db2"     │
│ thanos-sidecar :10901 ◄──────────┼─┼──► thanos-sidecar :10901        │
│ thanos-query   (reads BOTH sidecars, dedup on "replica")             │
│ alertmanager   :9093  ◄─ gossip :9094 ─► alertmanager :9093          │
│ grafana        → local thanos-query                                  │
│ keepalived     priority 150      │ │ keepalived     priority 100      │
│ pushgateway    (A only)          │ │                                  │
└──────────────────────────────────┘ └──────────────────────────────────┘
                    │                           │
                    └────── both Prometheus ────┘
                     send alerts to BOTH Alertmanagers
```

prod3 is intentionally not a monitoring node: two collectors are enough for availability, and unlike
etcd there is no quorum to protect, so a third node adds cost without adding safety.

### Components

| | |
|---|---|
| Base | dockprom (current `master` image versions) |
| Prometheus | v3.10.0 · 2 replicas · `replica` external label |
| Thanos | sidecar + query · version pinned at build time |
| Alertmanager | v0.31.1 · 2-node gossip cluster |
| Grafana | 12.4.0 · 1 per node · stateless (provisioning-only) · active/passive behind VIP |
| keepalived | 1 per node · VRRP unicast · health-checks local Grafana |
| Exporters | node-exporter v1.10.2 · cAdvisor v0.55.1 · on every host |
| Pushgateway | v1.11.2 · single instance (see [Known limitations](#known-limitations)) |

### Ports

All published on the host IP. To be checked for collisions on each server before deployment —
cAdvisor's `8080` in particular is a common clash.

| Service | Port | Exposed to |
|---|---|---|
| node-exporter | 9100 | both Prometheus nodes |
| cAdvisor | 8080 | both Prometheus nodes |
| Prometheus | 9090 | local node only |
| Thanos sidecar gRPC | 10901 | both Thanos Query instances |
| Thanos Query HTTP | 10904 | local Grafana, operators |
| Alertmanager HTTP | 9093 | both Prometheus nodes, operators |
| Alertmanager gossip | 9094 tcp+udp | the other Alertmanager |
| Grafana | 3000 | users, via the Grafana VIP (nginx-proxy on the VIP holder) |
| VRRP | IP protocol 112 (unicast) | the other keepalived — not a TCP/UDP port; firewall must allow it |
| Pushgateway | 9091 | batch jobs, both Prometheus nodes |

---

## Changes from dockprom, file by file

**`docker-compose.yml`**
- Remove `container_name:` from every service.
- Replace `expose:` with host-published `ports:` for anything reached across hosts (table above).
- Split into two profiles: `exporters` (every host) and `monitor` (db1, db2).
- Prometheus: add `--storage.tsdb.min-block-duration=2h` and `--storage.tsdb.max-block-duration=2h`
  (required by the Thanos sidecar).
- Add `thanos-sidecar` (shares the `prometheus_data` volume) and `thanos-query`.
- Alertmanager: add `--cluster.listen-address=0.0.0.0:9094` and `--cluster.peer=<other node>:9094`.
- Drop Caddy; Grafana is published through the existing nginx-proxy (`VIRTUAL_HOST`), consistent with
  the other services on these hosts. The Grafana hostname resolves to the Grafana VIP, so whichever
  host holds the VIP serves it from its local Grafana.
- Grafana: keep dockprom's local `grafana_data` SQLite volume, but treat it as disposable — everything
  that matters comes from git. Identical settings on both nodes:
  ```yaml
  environment:
    GF_SERVER_ROOT_URL: https://grafana.amf/   # the VIP hostname, same on both nodes
    GF_UNIFIED_ALERTING_ENABLED: "false"       # alerting lives in Prometheus/Alertmanager only
    GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
    GF_USERS_ALLOW_SIGN_UP: "false"
  ```
  Grafana-managed alerting is turned off because its rules would live in each node's SQLite and
  silently differ between nodes. If users authenticate via LDAP, the same `ldap.toml` is mounted on
  both nodes, so accounts are identical; only the login session is per node.
- Add `keepalived` (host network, `NET_ADMIN`, and `tmpfs: [/run]`), one per node. The tmpfs matters:
  without it a pid file survives a container restart or host reboot and keepalived refuses to start
  ("daemon is already running") — found in rehearsal.
  ```
  vrrp_script chk_grafana {
      script "curl -fsS http://127.0.0.1:3000/api/health"
      interval 2
      fall 3
      rise 2
  }
  vrrp_instance GRAFANA {
      state BACKUP              # both BACKUP + nopreempt: VIP does not bounce back on recovery
      nopreempt
      interface <host iface>    # ens259f0 on db1, ens259f0np0 on db2
      virtual_router_id <unused id>
      priority 150              # 100 on db2
      unicast_src_ip 10.10.10.20
      unicast_peer { 10.10.10.21 }
      virtual_ipaddress { <GRAFANA VIP>/24 }
      track_script { chk_grafana }
  }
  ```
  The VIP is a new address, separate from the Postgres VIP. vip-manager is not reused: it follows
  Patroni's leader key in etcd, which says nothing about whether Grafana is healthy.

**`prometheus/prometheus.yml`**
```yaml
global:
  external_labels:
    cluster: amfileon
    replica: db1            # db2 on the other node — the ONLY difference between the two files

scrape_configs:
  - job_name: nodeexporter
    static_configs:
      - targets: ['10.10.10.20:9100', '10.10.10.21:9100', '10.10.10.13:9100', ...]
  - job_name: cadvisor
    static_configs:
      - targets: ['10.10.10.20:8080', '10.10.10.21:8080', '10.10.10.13:8080', ...]

alerting:
  alert_relabel_configs:      # REQUIRED — see below
    - action: labeldrop
      regex: replica
  alertmanagers:
    - static_configs:
        - targets: ['10.10.10.20:9093', '10.10.10.21:9093']   # both, always
```
The `replica` value is set per host through an environment variable (`replica: ${REPLICA}`);
Prometheus 3 expands it natively, so the file in git is identical on both nodes.

`alert_relabel_configs` is not optional: alerts carry the external labels, so without dropping
`replica` the same alert arrives at Alertmanager as two different alerts (one per Prometheus) and
every notification is sent twice.

**`grafana/provisioning/datasources/`** — datasource URL changes from `http://prometheus:9090` to
`http://thanos-query:10904`.

**`grafana/provisioning/dashboards/`** — each dashboard JSON gets a fixed `"uid"` (dockprom's have
none, so each Grafana invents a random one and a bookmarked `/d/<uid>` link breaks after failover —
found in rehearsal). The provider is made read-only so the two nodes cannot drift apart:
```yaml
providers:
  - name: default
    allowUiUpdates: false   # edits go through git, not the UI
    disableDeletion: true
```
To change a dashboard: edit it in the UI, use *Export → JSON*, commit the file, redeploy both nodes.

**`alertmanager/config.yml`** — unchanged.

---

## Behaviour — what happens when a node dies

```mermaid
sequenceDiagram
    participant T as Targets (exporters)
    participant PA as db1 · Prometheus
    participant PB as db2 · Prometheus
    participant QB as db2 · Thanos Query
    participant AM as Alertmanager cluster
    participant G as db2 · Grafana

    loop every scrape interval
        T-->>PA: metrics
        T-->>PB: metrics
    end
    Note over PA: db1 goes down (t+0)
    loop every scrape interval
        T-->>PB: metrics (still collected)
    end
    G->>QB: dashboard query
    QB->>PB: via sidecar (db1 sidecar unreachable, skipped)
    PB-->>G: complete data, no gap
    PB->>AM: InstanceDown{instance=db1}
    Note over AM: db2 Alertmanager notifies — once
    Note over PA: db1 recovers
    QB->>PA: reads again; db1's gap filled from db2 via dedup
```

1. **Collection continues** — db2's Prometheus never depended on db1; it keeps scraping every target.
2. **Queries continue** — db2's Thanos Query marks db1's sidecar unreachable and answers from db2
   alone. Dashboards on db2's Grafana show unbroken data.
3. **Alerting continues — and reports the failure** — db2's Prometheus fires `InstanceDown` for db1's
   exporters; db2's Alertmanager sends the notification. This is the property the current setup
   lacks: losing the monitoring host is itself alerted on.
4. **Recovery is automatic** — when db1 returns, its Prometheus resumes scraping. Its own TSDB has a
   gap, but queries through Thanos de-duplicate across both replicas, so the gap is invisible.

5. **The Grafana address follows** *(measured in rehearsal: 5s)* — db2's
   keepalived stops hearing db1's advertisements, raises the Grafana VIP and sends gratuitous ARP.
   Users on `grafana.amf` see a few seconds of errors, are asked to log in once, and then see the same
   dashboards — db2's Grafana was built from the same files. When db1 returns, the VIP stays on db2
   (`nopreempt`), so there is no second interruption.

The same VIP move happens if only db1's Grafana container fails while the rest of db1 is fine — the
health check, not host liveness, decides where the address lives.

Grafana has no external dependency: it does not touch the Postgres cluster, so database incidents
never affect dashboards.

---

## Validation plan — local rehearsal first

Before anything touches db1 or db2, the full design runs on a single laptop, with containers standing
in for hosts — the same approach used for the Postgres cluster in
[`postgres_cluster/local-rehearsal/`](../postgres_cluster/local-rehearsal/).

```
node-a        prometheus(replica=a) · thanos-sidecar · thanos-query · alertmanager · grafana · keepalived · pushgateway
node-b        prometheus(replica=b) · thanos-sidecar · thanos-query · alertmanager · grafana · keepalived
target-1..3   node-exporter · cadvisor          (stand-ins for prod3 / cpu1 / gpu1)
webhook-sink  fake alert receiver that records every notification it gets
client        curl container on the same network, used to reach the Grafana VIP
```

The Grafana VIP is a spare address inside the rehearsal network's fixed subnet; keepalived runs with
`NET_ADMIN` in each node's network namespace using VRRP unicast.

**Acceptance tests** (`run-acceptance-tests.sh`, re-runnable later against the real hosts):

| # | Test | Pass condition |
|---|---|---|
| 1 | Steady state | Both Prometheus scrape all targets; Thanos Query returns **one** series per target, not two |
| 2 | Lose one Prometheus | Stop Prometheus A → queries and Grafana panels on both nodes still answer |
| 3 | Gap fill | Restart A → a query spanning the outage window has no gap |
| 4 | Alert de-duplication | Fire a test alert → webhook sink receives it **exactly once** (2 Prometheus × 2 Alertmanager) |
| 5 | Lose a whole node | Stop every node-a container → node-b's Grafana, Thanos Query and alerting keep working; `InstanceDown` for node-a is delivered |
| 6 | Silence propagation | Create a silence on Alertmanager A → it appears on Alertmanager B |
| 7 | Node rejoin | Restart node-a → it rejoins the gossip cluster and Thanos Query sees both sidecars again |
| 8 | Grafana VIP failover | Stop node-a's Grafana → VIP moves to node-b within 10s; after one login, the same dashboards load with data |
| 9 | No flap-back | Restart node-a's Grafana → VIP stays on node-b |
| 10 | No drift | Both Grafanas return the identical dashboard list and datasource config; a UI save of a provisioned dashboard is rejected |

**What the rehearsal proves:** the design and its failure behaviour.
**What it cannot prove:** real-network effects (firewalls, actual IPs), production scrape load and disk
growth, x86_64-specific behaviour (the laptop is arm64; all images are multi-arch, so risk is low),
and whether the real switches and firewalls pass VRRP and gratuitous ARP.
Those are covered by re-running the same test script on the servers in rollout phase 2.

**Running it** (from [`local-rehearsal/`](local-rehearsal/), about 6 minutes):

```bash
docker compose up -d --build
./run-acceptance-tests.sh
docker compose down -v
```

While it is up: node-a Grafana at <http://localhost:13000>, node-b at <http://localhost:23000>
(`admin` / `rehearsal`), node-a Thanos Query at <http://localhost:13904>.

### Rehearsal results — 2026-10-12

Run on a MacBook (Docker 29.3.1, arm64), clean stack. **28 of 28 checks passed.**

| # | Test | Result |
|---|---|---|
| 1 | Steady state | 5 series de-duplicated, 10 without de-duplication — both replicas hold a full copy |
| 2 | Lose one Prometheus | Both Thanos Queries and both Grafanas kept answering |
| 3 | Gap fill | node-a's own copy had a 54s gap; de-duplicated view's largest gap was 5s (one scrape) |
| 4 | Alert de-duplication | `monitor_service_down` delivered exactly once |
| 5 | Lose a whole node | VIP on node-b, Grafana up via VIP, node-a's loss alerted once by node-b |
| 6 | Silence propagation | Silence created on A active on B |
| 7 | Node rejoin | Gossip rejoined; node-b's Thanos reconnected to node-a's sidecar after 38s |
| 8 | Grafana VIP failover | VIP moved in **5s**; login and dashboards worked via the VIP |
| 9 | No flap-back | VIP stayed put when the failed Grafana recovered |
| 10 | No drift | Identical dashboards and datasources; saving a provisioned dashboard rejected (HTTP 400) |

**Found by the rehearsal and fixed in this design** — none of these were visible on paper:

1. **keepalived would not restart** after its container restarted: a stale pid file made it exit with
   "daemon is already running" in a loop, so the node could never hold the VIP again. Fix:
   `tmpfs: [/run]`. The same would happen on a real host after a reboot.
2. **Dashboard UIDs differed between the two Grafanas**, because dockprom's dashboard files have no
   `uid`. Bookmarked links would break after every failover. Fix: fixed `uid` in each JSON file.
3. **Thanos reconnect after a node returns takes tens of seconds**, not seconds. Not a defect —
   recorded under Known limitations.

The `replica` label drop on alerts (`alert_relabel_configs`) was added while building the
rehearsal, before the first run; test 4 confirms it works.

---

## Rollout plan

| Phase | What | Risk to current monitoring |
|---|---|---|
| **0 · Rehearsal** | Build and pass all tests locally | None |
| **1 · Exporters + prerequisites** | Deploy `exporters` profile to every host. Allocate the Grafana VIP and a VRRP router id; add the DNS name | None — additive |
| **2 · Parallel run** | Deploy `monitor` profile on db1 + db2 alongside existing dockprom; re-run acceptance tests on the real hosts, including a VIP failover drill | None — old stack untouched |
| **3 · Cutover** | Point users at `grafana.amf` and alert receivers at the new Alertmanagers; stop old dockprom | Low — old stack can be restarted |
| **4 · Decommission** | After 200h (old retention) remove old dockprom and its 7.8 GB `dockprom_prometheus_data` volume | None |

**Rollback** at any point before phase 4: `docker compose up -d` in the old dockprom directory on db1.
Its data volume is not touched until phase 4.

---

## Known limitations

- **Pushgateway stays single-instance.** It is not designed for HA. It runs on db1 and both
  Prometheus scrape it; if db1 is down, pushed batch-job metrics are missing until it returns.
  Collected scrape metrics are unaffected.
- **Duplicate notifications are possible during a network partition.** If db1 and db2 cannot reach
  each other but both can reach the notification channel, each Alertmanager may notify once. This is
  Alertmanager's documented trade-off: it prefers a duplicate alert over a missed one.
- **Retention is per node.** Without object storage, each node holds 200h of history. Long-term
  retention via Thanos → MinIO is a possible follow-up, not part of this proposal.
- **Two monitoring nodes share the db1/db2 failure domain** with the Postgres cluster. A simultaneous
  loss of both hosts takes down monitoring and the database together. Acceptable for now; noted for
  the record.
- **Users log in again after a Grafana failover.** Sessions are per node. Accepted: failovers are
  rare and re-login takes seconds.
- **Dashboards are edited through git, not the UI.** Provisioned dashboards are read-only so the two
  nodes stay identical. UI edits are still possible as a scratch copy, then exported and committed.
- **Failover is not instant.** Users see about 5 seconds of errors while the Grafana VIP moves.
- **A returning node's history reappears with a delay.** After a node rejoins, the other node's
  Thanos Query can take up to ~1 minute (38s measured) to reconnect to its sidecar because of gRPC
  reconnect backoff. Nothing is missing meanwhile — each node's own copy is complete.
- **No detection of total monitoring loss.** If both nodes fail together, or a broken config or
  notification channel reaches both, nothing alerts on it. Accepted — see Decisions taken.

---

## Decisions taken

- **Grafana access: one address, active/passive, stateless** (2026-10-07). Two Grafanas behind a
  keepalived floating IP, each built only from provisioning files in git. Chosen over two separate
  URLs so users never have to know which node is up.
- **Rejected: Grafana state in the shared Patroni database** (2026-10-07). It would keep sessions and
  UI edits across failover, but needs a database, user and mTLS client certificate on Patroni, and
  makes dashboards unavailable whenever Postgres is down or failing over — monitoring depending on
  what it monitors. Re-login and git-only dashboard edits were judged the smaller cost.
- **Not adopted: external dead man's switch** (2026-10-07). An always-firing `Watchdog` alert pinging
  an external heartbeat service would detect total monitoring loss. Out of scope: simultaneous loss
  of both nodes is not considered a risk worth covering now. It can be added later with one alert
  rule and one Alertmanager route.

## Open decisions

1. **Grafana VIP address and VRRP router id** — a free address on `10.10.10.0/24` and a
   `virtual_router_id` not used by anything else on the segment.
2. **Long-term storage.** Is 200h (~8 days) of history enough, or should a follow-up add Thanos → MinIO?

---

## Proposed directory layout

```
dockprom_HA_cluster/
├── README.md                     this document
├── local-rehearsal/
│   ├── docker-compose.yml        node-a, node-b, target-1..3, webhook-sink, client
│   ├── prometheus/               prometheus.yml (replica via env), alert.rules
│   ├── alertmanager/             config.yml
│   ├── grafana/provisioning/     datasources → thanos-query, dashboards from dockprom
│   ├── keepalived/               keepalived.conf per node
│   ├── tools/ webhook-sink/      keepalived + test-client image; fake notification receiver
│   └── run-acceptance-tests.sh   tests 1–10 above
└── deploy/
    ├── exporters/docker-compose.yaml      every host
    ├── db1/docker-compose.yaml + .env     monitor node A
    └── db2/docker-compose.yaml + .env     monitor node B
```
