# GitLab on db1 with failover to db2

**Design proposal, prepared 2026-10-07**

Status: proposal only, nothing deployed · goal: `gitlab.amf` keeps working when db1 is down ·
target: about 10 min to recover (RTO), about 0 DB loss and a few minutes of file loss (RPO)

---

## Goal

Today `gitlab.amf` (along with `registry.amf`, `pages.amf` and SSH on port 10023) runs as a single
container on db1. If db1 goes down, GitLab is down until db1 is repaired or restored from a backup.

The goal is **active/passive failover**. GitLab runs on db1 only. db2 holds an up-to-date copy and a
stopped, identical GitLab container. If db1 fails, GitLab is started on db2 and the GitLab hostnames
are moved to db2.

This is not active/active, where both nodes serve traffic at the same time. That is a much bigger
project (see [Alternatives considered](#alternatives-considered)).

---

## Current state (db1)

Source: `/srv/docker/gitlab-ee/docker-compose.yaml` on db1 and
[db1-storage-overview.md](../storage_management/db1-storage-overview.md).

| Item | Value |
|---|---|
| Compose dir / container | `/srv/docker/gitlab-ee` / `gitlab-ee` |
| Image in compose | `gitlab/gitlab-ce:latest` |
| Version actually running | **19.4.0** (untagged image, per the storage report) |
| Volumes | `gitlab_config` → `/etc/gitlab`, `gitlab_data` → `/var/opt/gitlab` (live volume: `gitlab-ee_gitlab_data`) |
| Hostnames | `gitlab.amf`, `registry.amf`, `pages.amf` via nginx-proxy (`VIRTUAL_HOST`), SSH on `10023` |
| Database | Bundled Postgres inside the container (main DB + registry metadata DB) |
| Registry storage | Filesystem, inside `gitlab_data` |
| Secrets | `db_key_base`, `secret_key_base` and `otp_key_base` come from `.env` (good: easy to copy to db2) |
| Host disk | `/data` on `/dev/md0`: 7.0 T, 6.4 T used, about 200 G available |

### What lives in `gitlab_data`

| Data | Size | How hard it is to replicate |
|---|---|---|
| Container registry blobs | **1.5 TB** (4,651 tags, 71 repos) | Hard because of size. Easy because blobs never change after they're written |
| Git repositories | 15 GB | Small |
| Packages / artifacts / uploads / pages | about 6 GB | Small |
| Bundled Postgres (main + registry DB) | a few GB | **Can't be safely copied while it's running.** Must move out of the container |
| Redis | small | Not worth replicating: losing it only drops sessions and queued jobs |
| `/etc/gitlab` (`gitlab-secrets.json`, SSH host keys, `gitlab.rb`) | tiny | Must be identical on db2 |

Leaving the registry aside, GitLab holds only about 25 GB. The plan below mostly addresses two
things: **Postgres** and **the registry**.

---

## Proposed design

```
                 gitlab.amf · registry.amf · pages.amf · ssh :10023
                                   │
                     GitLab floating IP or DNS record
                    (points at whichever host is "active")
                                   │
          ┌────────────────────────┴────────────────────────┐
          ▼  ACTIVE                                         ▼  STANDBY
┌──────────────────────────┐   rsync every 5–15 min ┌──────────────────────────┐
│ db1                       │ ─────────────────────► │ db2                       │
│ gitlab-ce 19.4.0 (running)│  repos, uploads,       │ gitlab-ce 19.4.0 (STOPPED)│
│ gitlab_data (files only)  │  artifacts, packages,  │ gitlab_data (copy)        │
│ gitlab_config             │  pages, registry blobs │ gitlab_config (copy)      │
└────────────┬──────────────┘                        └────────────┬──────────────┘
             │                                                    │
             └────────────► Patroni cluster (VIP 10.10.10.18:15432) ◄───┘
                            gitlabhq_production + registry DBs
                            already replicated db1 ⇄ db2, automatic failover

        etcd key /amf/gitlab/active = db1 | db2   → start guard (see "Split-brain")
```

### 1. Move GitLab's databases to the Patroni cluster

This is the key step. Patroni already replicates between db1 and db2 and fails over automatically
(about 30 s). Once GitLab's main DB and registry DB live there, the database layer of GitLab is
already HA, with essentially no data loss.

```ruby
# GITLAB_OMNIBUS_CONFIG additions
postgresql['enable'] = false
gitlab_rails['db_adapter']  = 'postgresql'
gitlab_rails['db_host']     = '10.10.10.18'
gitlab_rails['db_port']     = 15432
gitlab_rails['db_database'] = 'gitlabhq_production'
gitlab_rails['db_username'] = 'gitlab'
gitlab_rails['db_password'] = '${GITLAB_DB_PASSWORD}'

registry['database'] = {
  'enabled'  => true,
  'host'     => '10.10.10.18',
  'port'     => 15432,
  'dbname'   => 'registry',
  'user'     => 'registry',
  'password' => '${REGISTRY_DB_PASSWORD}',
  'sslmode'  => 'prefer',
}
```

Migration (one-time, needs a maintenance window):
1. Check the PG major version. Patroni runs PG17, and GitLab 19.x must support it.
2. Create the `gitlab` and `registry` roles and DBs on Patroni, plus the extensions GitLab needs
   (`pg_trgm`, `btree_gist`, `plpgsql`, `amcheck`).
3. Stop GitLab (`gitlab-ctl stop puma`, `gitlab-ctl stop sidekiq`, and `registry`), keeping the
   bundled Postgres running.
4. `pg_dump` both DBs from the bundled Postgres, then `pg_restore` them into Patroni.
5. Apply the new config, `gitlab-ctl reconfigure`, then check with `gitlab-rake gitlab:check` and
   `gitlab-ctl registry-database` status.

### 2. Replicate the files from db1 to db2 with rsync

| Data | Method | Interval | Notes |
|---|---|---|---|
| Registry blobs | `rsync -a` (without `--delete` while syncing; prune separately) | 15 min | Content-addressed and never changed, so after the first copy each run only sends new layers |
| Repos (`git-data`) | `rsync -a --delete` | 5–15 min | Copying live repos isn't officially supported, but git tolerates it. Worst case: losing pushes since the last run |
| Uploads, artifacts, packages, LFS, pages (`gitlab-rails/shared`, `gitlab-rails/uploads`) | `rsync -a --delete` | 5–15 min | Small |
| `/etc/gitlab` | `rsync -a` | on change | Must include `gitlab-secrets.json` and `ssh_host_*` keys |

**Do registry cleanup first.** The cleanup policies in the
[registry report](../storage_management/db1-registry-storage-report.md) remove about 89 % of tags
(about 1 TB). That shrinks the initial copy from 1.5 TB to about 0.5 TB.

Known gap: the registry DB (on Patroni) is replicated almost instantly, but blobs only arrive with
the next rsync. After a failover, images pushed in the last few minutes appear in the registry but
fail to pull. The fix is to push them again.

### 3. Standby GitLab on db2

- Same compose file and the same `.env` (secrets) as db1.
- **Pin the version on both hosts:** `image: gitlab/gitlab-ce:19.4.0-ce.0` instead of `:latest`.
  If the two hosts run different versions, the standby can run DB migrations on failover, or fail to
  start at all.
- nginx-proxy on db2 needs the same `VIRTUAL_HOST` entries.
- The container is created but **not running**.
- Upgrades become: upgrade db1 → change the pinned version on db2 (don't start it).

### 4. Routing: how `gitlab.amf` reaches the active host

`gitlab.amf`, `registry.amf`, `pages.amf` and SSH `10023` all need to move together. There are two
ways to do it:

| Option | How | Pros / cons |
|---|---|---|
| **Floating IP** (keepalived) | A separate IP, for example 10.10.10.x, held by the active GitLab host; DNS points at it permanently | Switches instantly, no DNS caching. Must be **separate from the Postgres VIP** 10.10.10.18, because the Postgres leader and the GitLab host are independent |
| **DNS change** | The failover script updates the A records | Simplest if DNS is easy to script. Clients may cache the old record for up to the TTL |

### 5. Failover: manual trigger, scripted steps

`failover-to-db2.sh`:
1. Confirm db1 is really down (it doesn't answer ping or SSH, or has been powered off).
2. Set `/amf/gitlab/active = db2` in etcd.
3. Run `docker compose up -d` on db2 and wait for `/-/readiness`.
4. Move the floating IP or DNS record.
5. Smoke test: log in, clone, push, `docker pull` from `registry.amf`.

GitLab takes 3–5 minutes to boot anyway, so an automatic trigger gains little. With only two GitLab
hosts, an automatic trigger risks split-brain.

**Failing back** (once db1 is repaired): stop the rsync job → rsync db2 → db1 → stop GitLab on db2 →
set `active = db1` → start db1 → move the IP or DNS back → restart the db1 → db2 rsync.

---

## Split-brain: the main risk

Once both hosts point at the same Patroni DB, this sequence becomes dangerous:

1. db1 goes down, and you fail over to db2.
2. db1 reboots, and **`restart: always` brings db1's GitLab back up.**
3. Two GitLabs now write to **one database** with **different repo copies**, which corrupts data.

**Fix:** don't rely on `restart: always` alone. Gate startup on an "active node" flag stored in etcd
(already running on db1, db2 and prod3):

- Key: `/amf/gitlab/active` → `db1` or `db2`.
- A small wrapper (systemd unit or entrypoint check) runs before GitLab starts. It refuses to start
  unless the key names this host.
- If etcd can't be reached, it **refuses to start**, so the default is to stay off.
- The wrapper needs an etcd client certificate signed by the cluster CA (etcd enforces mTLS; see
  [postgres_cluster architecture](../postgres_cluster/docs/architecture.md)).

The same flag tells the rsync job which direction to copy in. It always copies **from** the active
host, never towards it.

---

## Expected result

| | Today | After this plan |
|---|---|---|
| db1 dies | GitLab down until db1 is repaired or restored | db2 serves `gitlab.amf` in **about 10 min** |
| DB data loss | everything since the last backup | **about 0** (Patroni replication) |
| File data loss | everything since the last backup | up to the rsync interval (5–15 min) |
| GitLab config changes | – | DB host settings, pinned image, start guard |

---

## Alternatives considered

| Option | Why not (for now) |
|---|---|
| **Full multi-node GitLab HA** (2+ Rails nodes, Redis Sentinel, Gitaly Cluster with Praefect, object storage for everything) | GitLab's smallest HA reference architecture is about 10+ nodes. It roughly triples what we operate and turns every upgrade into a multi-node rolling procedure. Too much for one internal GitLab |
| **GitLab Geo** (built-in warm standby) | Premium/Ultimate only. We run CE |
| **Omnibus-bundled Patroni/Consul/PgBouncer** | Premium only. Not needed: we already have our own Patroni cluster |
| **DRBD** (block-level replication of the whole volume) | Needs a spare block device on both hosts. `/data` on db1 is a full md RAID with 200 G free, so it doesn't fit |
| **Object storage (MinIO) for registry, uploads, artifacts** | Would make the files stateless, but MinIO is currently a single drive on db1 (`minio-s3-1`), so it would just move the single point of failure. Worth revisiting if MinIO gets replication to db2 |
| **Nightly backup + restore on db2** | Simplest, but up to 24 h of data loss and a recovery measured in hours. Good as a baseline either way |

---

## Prerequisites and open questions

- [ ] **db2 free disk space:** at least 1.5 TB, or about 0.5 TB after registry cleanup.
- [ ] **How `gitlab.amf` resolves today:** a DNS A record pointing at db1, or something else? This
      decides between a floating IP and a DNS change.
- [ ] **Free IP** for a GitLab floating IP (if that option is chosen).
- [ ] **PG compatibility:** GitLab 19.4 vs Patroni PG17, and the required extensions available.
- [ ] **Patroni capacity:** room for GitLab's connection count (Puma + Sidekiq) within
      `max_connections`.
- [ ] **Patroni `max_locks_per_transaction` ≥ 128.** Found in the local rehearsal: with the
      Postgres default of 64, GitLab's schema load fails with `out of shared memory` /
      `increase max_locks_per_transaction`. The current Patroni configs don't set it. It's a
      restart-level setting, so set it in Patroni's DCS config and do a rolling restart before
      migrating.
- [ ] **Pin** `gitlab/gitlab-ce:19.4.0-ce.0` in the db1 compose file (do this now, regardless).
- [ ] **Backups:** `gitlab-backup create` plus a separate copy of `gitlab-secrets.json` and
      `gitlab.rb`, and one restore test. Do this now, regardless.

---

## Suggested order of work

1. Pin the image version and confirm backups and restore work (low risk, do now).
2. Run registry cleanup policies and let online GC free the space (24–48 h).
3. **Local rehearsal** on a laptop: two GitLab containers as "db1"/"db2", one Postgres as a stand-in
   for Patroni, the rsync job, the etcd start guard and the failover script. Test: push a repo and an
   image → kill "db1" → fail over → verify on "db2" → fail back. About 8–10 GB RAM.
4. Migrate GitLab's DBs to Patroni (maintenance window).
5. Set up the initial rsync to db2 and the standby container (stopped).
6. Set up the start guard, the routing (floating IP or DNS) and the failover script.
7. Do a real failover drill out of hours, then fail back.
