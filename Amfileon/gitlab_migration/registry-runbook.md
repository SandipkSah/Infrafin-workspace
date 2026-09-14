# GitLab Registry — Metadata DB Migration Runbook

**Goal:** Migrate the container registry (~1.8 TB) to the next-generation **metadata database**. The image
**blobs stay where they are** — only the metadata is imported into Postgres. Online GC then cleans up
orphaned/untagged images automatically.

**Two approaches — ⭐ preferred: Approach B (one-step):**

| | Approach A — Dedicated Postgres + 3-step import | ⭐ Approach B — Bundled Postgres + one-step import |
|---|---|---|
| DB | Separate `registry-db` container | GitLab's built-in Postgres (auto-provisioned) |
| Import | 3 steps (pre-import runs **online**) | 1 command |
| Read-only window | **Short** (final step only) | **Whole import** (registry read-only throughout) |
| Setup | More (extra container + network) | **Least** — easiest |
| Use when | Large registry, downtime matters | Simplicity matters / smaller registry / a window is OK |

**Preferred: Approach B (one-step)** — simplest, one command, no extra container. Acceptable as long as the
read-only import window (see below) fits in a maintenance window.

> Run all commands inside the GitLab container that hosts the 1.8 TB registry (called `<gitlab>` below).
> Blobs are never copied — the import only reads existing metadata and writes DB records.

---

## Estimated time

Import time scales with the **number of tagged images / manifests / layers — NOT the 1.8 TB.** Byte size
barely matters (a few large images import fast; many small tags import slowly). So measure first:
```bash
# how many repositories/tags?
curl -s -u <u>:<p> https://<registry>/v2/_catalog | jq '.repositories | length'
# real estimate without committing anything (processes but does not write):
docker exec <gitlab> gitlab-ctl registry-database import --dry-run --row-count --log-to-stdout
```

Rough ballpark (**estimates** — confirm with the dry-run):

| Registry (by tag count) | ⭐ One-step (B) — read-only | Three-step (A) — read-only |
|---|---|---|
| Small (< 1k tags) | minutes – 1 h | minutes |
| Medium (1k – 10k) | 1 – several h | minutes – ~1 h |
| Large (10k – 100k+) | several – 10 h+ | ~1 h or less |

- **One-step (B):** the read-only window = the **whole import**.
- **Three-step (A):** the long pre-import runs **online**; only the short final sync is read-only.

At 1.8 TB you likely have a substantial tag count, so the one-step read-only window could be **hours** —
fine if you run it off-hours/weekend. **Run the `--dry-run` first** to turn this into a real number before
committing to a window; if it comes back too long to tolerate, fall back to Approach A.

---

## Common prerequisites (both approaches)

- [ ] **Back up first:** `/etc/gitlab` (config + `gitlab-secrets.json`) and the registry DB. Blobs stay in place.
- [ ] **Confirm the storage backend** (needed for the read-only step + sanity):
      `docker exec <gitlab> sed -n '/storage/,/http/p' /var/opt/gitlab/registry/config.yml`
- [ ] **Disable any offline-GC cron** — once on the DB, online GC takes over; running old offline
      `registry-garbage-collect` against a DB registry **deletes live data**.
- [ ] Note the **image/tag count** (drives import time, not the TB):
      `curl -s -u <user>:<pass> https://<registry>/v2/_catalog | jq '.repositories | length'`.
- [ ] DB + user are named **`registry`** (GitLab 18.3+ expects this — a mismatch is the known data-loss trap).
- [ ] Agree a maintenance window.

---

## Approach A — Dedicated Postgres + 3-step import (minimal downtime)

### A1. Add the standalone Postgres + point the registry at it (disabled)
Add to `docker-compose.yaml` (start `enabled => false` so it keeps serving legacy during import):
```yaml
services:
  gitlab:
    # ...existing...
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        # ...existing config...
        registry['database'] = {
          'enabled'  => false,               # false during import; flip to true in A3
          'host'     => 'registry-db',
          'port'     => 5432,
          'user'     => 'registry',
          'password' => "${REGISTRY_DB_PASSWORD}",
          'dbname'   => 'registry',
          'sslmode'  => 'disable'
        }
    networks:
      - registry-internal                    # must share a network with registry-db
      # ...plus existing networks...

  registry-db:
    image: postgres:17-alpine
    restart: always
    environment:
      POSTGRES_DB: registry
      POSTGRES_USER: registry
      POSTGRES_PASSWORD: ${REGISTRY_DB_PASSWORD}
    volumes:
      - registry_db_data:/var/lib/postgresql/data
    networks:
      - registry-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U registry -d registry"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  registry_db_data:
networks:
  registry-internal:
    driver: bridge
```
Apply:
```bash
docker compose config | grep -i registry_db_password    # confirm it interpolates (quoted → valid Ruby)
docker compose up -d
docker exec <gitlab> getent hosts registry-db           # must resolve (shared network)
docker exec <gitlab> gitlab-ctl reconfigure             # applies connection + runs schema migrations
```

### A2. Import (3-step)
```bash
docker exec <gitlab> gitlab-ctl registry-database import --help   # confirm exact flags for your version

docker exec <gitlab> gitlab-ctl registry-database import --step-one-pre-import   # ONLINE, read-write (long part)
docker exec <gitlab> gitlab-ctl registry-database import --step-two-import       # SHORT read-only window
```

### A3. Switch on
Edit compose: `'enabled' => false` → `'enabled' => true`, then:
```bash
docker compose up -d && docker exec <gitlab> gitlab-ctl reconfigure
```
→ continue to **Verify**.

---

## ⭐ Approach B — Bundled Postgres + one-step import (easiest, PREFERRED)

📖 **Official docs:** [One-step import — GitLab Docs](https://docs.gitlab.com/administration/packages/container_registry_metadata_database_one_step_import/)

No extra container. Registry is **read-only for the whole import**. The one command that does the real
work is `gitlab-ctl registry-database import --log-to-stdout`.

### B1. In `GITLAB_OMNIBUS_CONFIG`: DB disabled + registry read-only
```ruby
registry['database'] = { 'enabled' => false }          # bundled Postgres, OFF during import

registry['storage'] = {
  'filesystem' => { 'rootdirectory' => '/var/opt/gitlab/gitlab-rails/shared/registry' },  # ← your REAL backend
  'maintenance' => { 'readonly' => { 'enabled' => true } }
}
```
⚠️ `registry['storage']` **replaces** the whole storage config — it must contain your actual backend
(filesystem path above, or your S3/GCS/MinIO block) **plus** the `maintenance` sub-block. Use the backend
you confirmed in the prerequisites.

### B2. Apply + schema migrations
```bash
docker compose up -d
docker exec <gitlab> gitlab-ctl reconfigure
docker exec <gitlab> gitlab-ctl registry-database migrate up
```

### B3. Import (one command)
```bash
docker exec <gitlab> gitlab-ctl registry-database import --log-to-stdout
```
Wait for completion (time ∝ image/tag count). Registry is read-only throughout.

### B4. Turn the DB on + read-only off
```ruby
registry['database'] = { 'enabled' => true }
registry['storage'] = {
  'filesystem' => { 'rootdirectory' => '/var/opt/gitlab/gitlab-rails/shared/registry' },
  'maintenance' => { 'readonly' => { 'enabled' => false } }
}
```
```bash
docker compose up -d && docker exec <gitlab> gitlab-ctl reconfigure
```
→ continue to **Verify**.

---

## ✅ Approach B — validated on test instance (2026-07-10)

Approach B was run end-to-end on the **`gitlab-ce2`** test instance (db2) and confirmed working.

**Setup for the test**
- GitLab CE 19.1.1, **bundled Postgres** (`registry['database'] = { 'enabled' => true }`, socket `host: /var/opt/gitlab/postgresql`, db/user `registry`).
- Registry pointed at **`http://localhost:5005`** (`registry_external_url` + `registry_nginx['listen_port']=5005`, port `127.0.0.1:5005:5005`) so images could be pushed with **no TLS/proxy** (Docker treats `localhost` as insecure). `registry2.amf`/certs were **not** involved.
- Seeded a legacy registry: **7 repos × 3 tags = 21 tags**, 72 MB on disk
  (traefik/whoami, busybox, alpine, nginx:alpine, redis:alpine, hashicorp/http-echo, hello-world).

**Steps executed**
1. Legacy start: `registry['database'] = { 'enabled' => false }`, seeded images (see test-plan doc).
2. Read-only + `enabled=false`: added `registry['storage']` with `maintenance.readonly.enabled = true` → `up -d` + reconfigure.
3. `gitlab-ctl registry-database migrate up` → **192 pre + 20 post migrations in 28.4 s** (creates the tables).
4. `gitlab-ctl registry-database import --log-to-stdout` (read-only active) → imported all 7 repos / 21 tags.
5. `enabled=true` + `readonly=false` → `up -d` + reconfigure.

**Results / evidence**
- **Read-only worked:** a push during the window was rejected with `unknown: Method not allowed` (HTTP 405).
- **Import time:** ~**4 s** for 21 tags (per log timestamps) → ≈ **0.2 s/tag**. Time scales with *tag count*, not the 72 MB.
- **After enabling:** `select count(*) from repositories` = **7**, `from tags` = **21** — matches the seed.
- **DB is live (read + write):** the previously-denied push then **succeeded**, and `tags` went **21 → 22**, proving the registry now reads *and writes* the SQL DB.
- Note: the `Gitlab-Container-Registry-Database-Enabled` header is **not** emitted on the unauthenticated `/v2/` 401 on this build — verify via the config (`database: {"enabled":true,…}`) and the tag-count jump instead.

**Learnings**
- The **one-step** command internally runs both a **pre-import** phase (manifests/configs/layers) and an **import** phase (tags) back-to-back — which is why it needs read-only for the whole duration.
- On the real 1.8 TB registry: multiply the measured per-tag rate by the real tag count to estimate the read-only window; run `--dry-run` first for a firm number.

---

## Verify (both approaches)

```bash
# metadata DB is now the active backend
docker exec <gitlab> curl -sI http://localhost:5000/v2/ | grep -i gitlab-container-registry-database-enabled  # true

# repositories imported (Approach A: query registry-db; Approach B: gitlab-psql)
docker compose exec registry-db psql -U registry -d registry -c "select count(*) from repositories;"   # A
docker exec <gitlab> gitlab-psql -d registry -c "select count(*) from repositories;"                    # B

# a known image still resolves
docker pull <registry>/<group>/<project>:<tag>
```

---

## Online garbage collection (cleans orphans)

Runs automatically once the DB is enabled. Monitor:
```bash
docker exec <gitlab> gitlab-ctl registry-database gc-stats
```
Expect high DB load and large review queues for 24–48 h; **storage shrinks gradually**, not immediately.
Temporarily speed it up by lowering the worker interval (default `5s`):
```ruby
registry['gc'] = { 'blobs' => { 'interval' => '1s' }, 'manifests' => { 'interval' => '1s' } }
```

---

## Rollback

- Restore the **pre-import backup** (config + secrets + registry DB). Blobs are untouched → the legacy
  registry is intact.
- ⚠️ After images are written to the DB, do **not** set `enabled => false` — that hides everything written
  while the DB was active. Roll back by restoring, not by toggling the flag.

---

## Key rules

- **`registry` naming is load-bearing** — DB + user must both be `registry` (18.3+). Never casually rename.
- **The import is NOT automatic.** Enabling the DB only creates empty tables (schema migrations); it does
  **not** import existing images. On an existing registry you **must** run the import above, or images
  become invisible.
- **Migrations auto-run on container start** (idempotent — real work only on version bumps).
- **Pin the GitLab image** (`gitlab/gitlab-ce:19.1.1-ce.0`) — `:latest` + an accidental `pull` triggers a
  migration on next start.
- **Back up before any upgrade** (incl. `registry_db_data` if using Approach A's dedicated DB).
- **Retire offline-GC scripts** after switching — they delete live data on a DB-backed registry.
- **`up -d` vs `reconfigure`** — env/`GITLAB_OMNIBUS_CONFIG` changes need `docker compose up -d` (recreate);
  gitlab.rb changes apply on reconfigure (auto on start).

---

## Reference

- Config reference: `gitlab-registry-config-reference.md` (same folder).
- [One-step import](https://docs.gitlab.com/administration/packages/container_registry_metadata_database_one_step_import/) ·
  [Metadata DB docs](https://docs.gitlab.com/administration/packages/container_registry_metadata_database/) ·
  [Registry admin / GC](https://docs.gitlab.com/administration/packages/container_registry/)
