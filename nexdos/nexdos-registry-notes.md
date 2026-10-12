# nexdos Registry — Current State & Online-GC Migration Notes

Working notes for whether/how to get the nexdos container registry onto a metadata-database /
online-GC setup, analogous to what was done for Amfileon. Captures what's confirmed on the live
host plus the actual `docker-compose.yaml`, so this doesn't need re-deriving later.

---

## 1. Why this isn't a drop-in repeat of the Amfileon process

Amfileon runs **Omnibus GitLab** (`gitlab/gitlab-ce`) — one container, `gitlab.rb`/`GITLAB_OMNIBUS_CONFIG`,
`gitlab-ctl`, and a **bundled registry process that is GitLab's own fork** of the Docker/Distribution
registry (`gitlab-org/container-registry`). That fork is what supports the metadata database
(`registry['database']`) and `gitlab-ctl registry-database migrate/import`.

nexdos runs **`sameersbn/gitlab`**, a from-source (non-Omnibus) build, paired with a **separate,
plain `registry:2`** container (upstream `docker/distribution`, unforked). Confirmed on-host:

```
docker exec gitlab which gitlab-ctl        → not found
docker exec gitlab ls /etc/gitlab/gitlab.rb → No such file or directory
docker exec registry registry --version    → registry github.com/docker/distribution 2.8.3
docker exec registry registry database --help → Error: unknown command "database"
```

**Conclusion: the metadata-database / online-GC feature is not available at all with the current
`registry:2` image — this is a binary capability gap, not a config gap.** No amount of
`GITLAB_OMNIBUS_CONFIG`/env-var tweaking on either container can add it, because the plain
distribution binary has no code path that knows how to read/write metadata from Postgres.

---

## 2. What `GITLAB_OMNIBUS_CONFIG` actually does on this image

The `gitlab` service sets `GITLAB_OMNIBUS_CONFIG` with Ruby/Omnibus-style directives, but only for
**GitLab KAS** (`gitlab_kas['enable']`, socket paths, `gitlab_kas_external_url`). Real config —
hostname, ports, HTTPS, DB, SMTP, LDAP, registry — is all done the standard **sameersbn way**, via
flat `GITLAB_*`/`DB_*`/`LDAP_*`/`SMTP_*` env vars. Since there's no `gitlab-ctl`/`gitlab.rb`, this
image's entrypoint must have a **custom, narrow parser** that only understands the `gitlab_kas[...]`
keys (to bolt on KAS support, which stock sameersbn lacks) — it is not a general Omnibus
interpreter. Other commented-out directives in the same block (`external_url`, `nginx[...]`) are
dead — they're not being applied (real HTTP config comes from `GITLAB_HOST`/`GITLAB_HTTPS`/etc.).

**Implication:** don't expect `registry['database'] = {...}` dropped into `GITLAB_OMNIBUS_CONFIG` to
do anything on this image, even setting the binary-capability issue aside.

---

## 3. Current registry auth/network wiring (from the real compose file)

```yaml
gitlab:
  environment:
    - GITLAB_REGISTRY_ENABLED=true
    - GITLAB_REGISTRY_HOST=registry.nexdos.de
    - GITLAB_REGISTRY_PORT=443
    - GITLAB_REGISTRY_API_URL=http://registry:5000       # internal, container-to-container
    - GITLAB_REGISTRY_KEY_PATH=/certs/registry.key        # private key, GitLab signs JWTs with this
    - GITLAB_REGISTRY_ISSUER=gitlab-issuer
    - GITLAB_REGISTRY_GENERATE_INTERNAL_CERTIFICATES=true # sameersbn auto-generates the keypair
  volumes:
    - certs-data:/certs        # shared with the registry container

registry:
  image: registry:2             # plain docker/distribution 2.8.3, confirmed no `database` subcommand
  volumes:
    - registry-data:/registry
    - certs-data:/certs         # shares the same volume → gets the public cert GitLab generated
  environment:
    - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/registry
    - REGISTRY_STORAGE_DELETE_ENABLED=true
    - REGISTRY_AUTH_TOKEN_REALM=https://git.nexdos.de/jwt/auth
    - REGISTRY_AUTH_TOKEN_SERVICE=container_registry
    - REGISTRY_AUTH_TOKEN_ISSUER=gitlab-issuer             # must match GITLAB_REGISTRY_ISSUER
    - REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE=/certs/registry.crt  # public cert, validates GitLab's JWTs
  ports:
    - "5000"                    # published to a random host port (seen earlier as 32782->5000)
```

**Auth mechanism:** `GITLAB_REGISTRY_GENERATE_INTERNAL_CERTIFICATES=true` means sameersbn generates
its own JWT signing keypair on the shared `certs-data` volume (`registry.key` private / `registry.crt`
public). GitLab signs tokens with the private key; the registry validates them against the public
cert via `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE`. Standard docker-token-auth spec — this same mechanism
is what a GitLab-fork registry image would also need to honor, so it should carry over to Option A
below without re-issuing certs, as long as the new image is pointed at the same `/certs` volume and
the same issuer/service/realm values.

**Correction to an earlier read:** the standalone `registry_config.yaml` on disk in `~/gitlab/` (no
`auth:` block, `rootdirectory: /var/lib/registry`) is **not actually mounted** — that compose line is
commented out (`#      - ./registry_config.yaml:/etc/docker/registry/config.yml`). The real,
active config is 100% the `REGISTRY_*` env vars above (rootdirectory `/registry`, not
`/var/lib/registry`). Treat `registry_config.yaml` as a stale reference file, not the live config.

**Storage backend:** plain filesystem (`/registry`) — no OSS/Swift driver, so the deprecation in
upstream issue [#1141](https://gitlab.com/gitlab-org/container-registry/-/issues/1141) doesn't apply.

**Checked sameersbn's own docs/issues for a v2→v3 JWT gotcha — real, but doesn't block this plan.**
sameersbn's [container_registry.md](https://github.com/sameersbn/docker-gitlab/blob/master/docs/container_registry.md)
warns: "Docker Registry v3 is currently not compatible with the JWT tokens signed by GitLab... uses
`registry:2` to avoid issues." Root cause, per [issue #3198](https://github.com/sameersbn/docker-gitlab/issues/3198):
plain upstream Distribution v3 dropped trusting `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE` alone and now
wants `REGISTRY_AUTH_TOKEN_JWKS` instead. **This is about the vanilla community `registry:3.0`
release, not GitLab's fork** — GitLab's own current standalone config docs still show
`rootcertbundle` as the auth key for their fork (versioned `v3.x.x-gitlab` but not carrying this
breaking change). So the existing `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE=/certs/registry.crt` setup
should still be correct for the `gitlab-container-registry` image — no JWKS needed — but confirm
`docker login`/push/pull on the throwaway test copy before trusting this on real data.

**Exposure note (unrelated to the DB question, worth a separate look):** the `registry` service
publishes port 5000 directly (`ports: ["5000"]`) in addition to being reachable via
`VIRTUAL_HOST=registry.nexdos.de` on the shared `proxy_network`. Since auth is enforced by the
registry itself (`REGISTRY_AUTH_TOKEN_*` env vars are present and correctly wired), a random
high host port alone isn't a bypass of auth — but it does mean the registry's `/v2/` endpoint is
reachable pre-TLS/pre-proxy on that port. Worth confirming host firewall rules restrict that port
to trusted networks only.

---

## 4. Options considered

| Option | What it is | Effort | Notes |
|---|---|---|---|
| **A — swap only the `registry` image** | Replace `registry:2` with a GitLab container-registry fork build (e.g. `registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:v3.15.0-gitlab`), add a `database:` block, provision a Postgres DB/user, run `migrate`/`import` directly on the new binary (no `gitlab-ctl` wrapper — this isn't Omnibus) | Moderate — roughly a day, same shape as the Amfileon `gitlab-ce2` test-then-cutover exercise | GitLab's own team calls this close to a "drop-in" (config/storage compatible per [#1557](https://gitlab.com/gitlab-org/container-registry/-/issues/1557)), but that issue is itself an **open, unresolved doc request** — no official runbook exists yet. Real operators have done this on plain docker-compose ([GitLab forum thread](https://forum.gitlab.com/t/container-registry-metadata-database-migration-on-docker-installation/111263)), hand-creating the `registry` Postgres role/DB themselves since the docs don't cover non-Omnibus. That same thread confirms a GitLab 18.3 regression caused **data loss** for people who misconfigured this — back up before touching anything real. |
| **B — migrate whole instance to Omnibus `gitlab/gitlab-ce`** | Reinstall as Omnibus, restore a `gitlab-backup` into it | Large, multi-day, high risk | Needs matching GitLab version on both sides, hand-carrying secrets (`GITLAB_SECRETS_DB_KEY_BASE`/`SECRET_KEY_BASE`/`OTP_KEY_BASE` → Omnibus's own secrets file), re-doing LDAP/SMTP/KAS/proxy config from scratch (KAS ironically gets *easier* under real Omnibus — natively supported, no custom parser needed). Far more downtime/risk than the actual goal (online GC) warrants. |
| **C — keep `registry:2`, use its native offline GC** | `docker exec registry registry garbage-collect --dry-run /etc/docker/registry/config.yml` (dry-run first) then without `--dry-run`, on a schedule/maintenance window | Low — no new container, no migration | No online GC; must accept a stop-writes-or-accept-missed-mid-run-pushes caveat during each run. Cheapest, but doesn't meet the "online GC" goal. |

**Working conclusion so far:** Option A is the right-sized move for the stated goal (online GC) —
contained to the `registry` service, doesn't touch the `gitlab` app container's sameersbn quirks,
and the auth wiring (§3) should transfer without re-issuing certs. Option B is disproportionate to
the goal. Option C is the fallback if A's testing surfaces a blocker.

---

## 5. Open items before committing to Option A

- [ ] Pick a `gitlab-org/build/cng/gitlab-container-registry` tag matching the GitLab version this
      sameersbn build corresponds to (18.11.x) — confirm token-auth compatibility isn't affected by
      version skew between GitLab app and registry-fork versions.
- [ ] Decide DB placement: point at a new `registry`/`registry_database` role on the existing
      `gitlab-postgresql` (sameersbn/postgresql:14) container, or stand up a dedicated Postgres —
      mirrors the Approach A vs B choice from the Amfileon runbook. Given `sameersbn/postgresql`'s
      own env-var-driven user/DB creation model, adding a second DB/user to it needs to be done by
      hand (`CREATE USER`/`CREATE DATABASE`) — same gap the forum thread hit.
  - [ ] Confirm the picked registry-fork image's expected Postgres config shape (host/port/user/
      password/dbname/sslmode) — likely still `database:` block in `config.yml`, not env vars.
- [ ] Build a throwaway copy of this stack first (same spirit as the Amfileon `gitlab-ce2` test) —
      seed a few repos/tags, run migrate+import, confirm `docker login`/push/pull still work against
      the existing `certs-data` keypair before touching the real `registry.nexdos.de` data.
- [ ] Back up `registry-data` volume + `gitlab-postgresql`'s data before any real attempt (mirrors
      the "back up first" rule from the Amfileon runbook — the 18.3 data-loss regression makes this
      non-negotiable).
- [ ] After cutover: retire/never run `registry garbage-collect` (offline GC) again — same rule as
      Amfileon, it deletes live data once the metadata DB is authoritative.

---

## 6. Manual offline GC on the current `registry:2` setup — working notes (2026-09-28)

Separate from the metadata-DB project above (§4 Option A) — this is running the **classic offline
GC** that plain `registry:2` already supports today (§4 Option C), as an immediate/interim action.

### Scale (measured on nexdos, 2026-09-28)

```bash
du -sh /var/lib/docker/volumes/gitlab_registry-data/_data   # 925G
```

Repo/tag counts via direct filesystem walk (no auth needed — reads the on-disk v2 layout directly:
`<root>/docker/registry/v2/repositories/<repo>/_manifests/tags/<tag>/`):

- **24 repositories, 3,034 tags total**
- Biggest by tag count: `dagster/user-code/pipeline` (658), `idp/nexdos_app/backend` (586),
  `idp/nexdos_app/frontend` (585), `idp/nexdos_app/frontend/cache` (418)
- **Blob count: 21,925** (measured 2026-09-28 via
  `find <root>/blobs/sha256 -mindepth 2 -maxdepth 2 -type d | wc -l`). This is the number that
  actually predicts GC sweep-phase duration (sweep walks every blob object), more so than tag count
  or raw GB. 925GB ÷ 21,925 ≈ 42MB average blob size — a moderate count of fairly large objects,
  not millions of tiny files, which is the favorable case for walk speed. Expect the `--dry-run`
  scan to land in low minutes on reasonable local disk I/O, not hours — the "large registry, hours+"
  caution in the Amfileon runbook context was calibrated for 100k+ tag/blob counts, well above this.

### Disk space blocker (hit 2026-09-28)

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/md2        3.5T  3.1T  248G  93% /
```
Only **248 GB free on `/`** (which also holds `/var/lib/docker`) — a full local backup of the
925 GB registry volume **does not fit on this host's disk at all**, regardless of destination
directory. Options identified: (a) find another mounted disk/NAS with 900GB+ free (`df -h` full +
`lsblk` — not yet checked), (b) stream a backup directly to a remote host via `rsync` (resumable,
no local intermediate copy needed), (c) free up space on `/` first, (d) skip the full backup and
rely on `--dry-run` review + readonly-mode discipline instead (see risk discussion below).

### Decision so far: skip full backup, lean on `--dry-run` + readonly mode

Confirmed the existing `GITLAB_BACKUP_SCHEDULE=daily` (sameersbn's built-in backup) does **not**
cover this at all — it runs inside the `gitlab` container, which only has `gitlab-data:/home/git/data`
and `certs-data:/certs` mounted; it has no filesystem access to `registry-data:/registry` at all.
Zero protection from that mechanism for this operation.

Given the local-backup space blocker, working approach agreed: **`--dry-run` first (free, makes zero
changes, safe to run without readonly mode — no race possible since nothing is deleted), review the
proposed deletions manually, then decide whether the real run's residual risk is acceptable** given
readonly mode will be on during the real pass (eliminates the concurrent-push race, which is the
main real failure mode of offline GC done correctly).

### Procedure (from §4 Option C, restated with nexdos specifics)

```bash
# 1. (optional, blocked by disk space above — revisit if a remote/other-disk target is found)
#    back up registry-data before the REAL (non-dry-run) pass

# 2. dry run — safe now, no readonly mode needed
docker exec registry registry garbage-collect --dry-run /etc/docker/registry/config.yml
# (config.yml path = image's built-in default; REGISTRY_* env vars still merge on top for this command)

# 3. before the REAL run only: enable readonly mode to block writes during the sweep
#    add to registry service env: REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED=true
docker compose up -d registry

# 4. real run
docker exec registry registry garbage-collect /etc/docker/registry/config.yml
# optional: --delete-untagged (more aggressive — also drops manifests with no tag; decide deliberately)

# 5. turn readonly back off, docker compose up -d registry, verify docker login/pull round-trip
```

### Per-repo storage breakdown (2026-10-12, informational only, no deletion)

Built from the dry-run log's `<repo>: marking blob <digest>` lines cross-referenced with real
on-disk blob sizes (`storage-analysis.py`, saved in `/Users/sandipsah/Desktop/infrafin/nexdos/`).
"Exclusive" = size if that repo alone were emptied (blobs referenced nowhere else); "inclusive" =
total referenced, double-counting layers shared with other repos.

**Storage is extremely concentrated — top 3 repos = ~89% of all registry data:**

| Repo | Exclusive GB | Blobs |
|---|---|---|
| `dagster/user-code/pipeline` | 470.38 | 7,441 |
| `idp/nexdos_app/backend` | 237.89 | 5,614 |
| `dagster/ops/images/nexdos-datalore-agent` | 151.15 | 1,144 |
| *(everything else, incl. all `/cache` repos)* | ~111 combined | — |

Sum inclusive: 984.33 GB · sum exclusive: 970.93 GB (close together → almost no cross-repo layer
sharing overall, except `.../nexdos-datalore-agent/datalore-agent` and the `idp/nexdos_k8s_app/backend`
pair, which share most layers with a sibling repo).

**Key finding: the `/cache` repos are not the real storage driver**, despite having high tag counts
— they total only ~48GB combined. The actual weight is in the primary app/pipeline image repos.
`dagster/user-code/pipeline` (658 tags, 7,441 blobs, ~714MB/tag average) and `idp/nexdos_app/backend`
show inclusive ≈ exclusive, meaning each CI build produces mostly-unique layers with little reuse —
so pruning old tags there would translate almost 1:1 into reclaimed space, with no shared-layer
discount complicating the estimate. These two repos (~73% of total storage) would be the
highest-leverage, lowest-risk starting point **if** a tag-retention/cleanup policy is ever pursued.
No tags have been deleted and no cleanup policy has been set up as of this note — purely
informational analysis so far.

### Tag age distribution (2026-10-12, informational only, no deletion)

Built from each tag's `_manifests/tags/<tag>/current/link` file mtime (proxy for "last pushed"),
via `tag-ages.py` (saved in `/Users/sandipsah/Desktop/infrafin/nexdos/`, full data in
`tag-ages-summary-2026-10-12.txt`). 3,228 tags total (up from 3,034 on 2026-09-28 — active growth).

**The three biggest storage repos also carry the heaviest stale-tag backlog:**

| Repo | Exclusive GB | Tags | >180 days old | Newest tag |
|---|---|---|---|---|
| `dagster/user-code/pipeline` | 470GB | 720 | 323 (45%), oldest 644d | 2.9d (active) |
| `idp/nexdos_app/backend` | 238GB | 620 | 273 (44%), oldest 283d | 1.8d (active) |
| `dagster/ops/images/nexdos-datalore-agent` | 151GB | 108 | 100 (93%!), oldest 1,053d | 46.6d (barely active) |

`idp/nexdos_app/frontend/cache`: 426 tags, oldest 489d, 65% >180d old — confirms the `/cache`
repos accumulate indefinitely (never overwritten) rather than being a genuine build-cache rotation.

**~14 repos are dormant** (newest tag itself is months–years old, not just old average age):
`dagster/pipeline-example` (newest tag 1,108d old), `idp/nexdos_k8s_app/frontend` (936d),
`dataflow/airbyte_poc` (1,526d), etc. A retention policy's "keep most recent N" floor won't clean
these — nothing new arrives to push the window forward. These need a manual "is this still needed"
call, not an automated expiry rule.

### Refined cleanup-policy recommendation (not yet applied — suggestion only)

- **Active big repos** (`pipeline`, `backend`, `datalore-agent`): keep most recent 10 tags, expire
  tags older than **90 days**, preserve regex `^(main|master|stable|latest|release-.*|v[0-9]+\.[0-9]+\.[0-9]+)$`.
- **Cache repos** (`*/cache`): keep most recent 2–3, expire older than 7 days. Root-cause fix:
  CI should push to one stable `:cache` tag (overwritten) instead of a unique tag per run.
- **Small/low-churn repos**: keep most recent 25, expire older than 90 days, same preserve regex.
- **Dormant repos**: flag for manual review (still needed at all?) rather than an automated policy.
- Rollout caution: cleanup policies apply retroactively on first run, no built-in dry-run in GitLab
  CE — recommended to enable on one repo first (e.g. `idp/nexdos_app/backend`), verify, then expand.
- Nothing has been enabled yet — this is a suggestion pending the user's decision.

### Policy simulation — real projected reclaim (2026-10-12, informational only, no deletion)

`policy-simulation.py` (saved in `/Users/sandipsah/Desktop/infrafin/nexdos/`) reads every tag's
actual manifest (exact blob/layer digests, recursing into manifest lists if present — more precise
than the repo-level GC-log attribution above) and simulates the §-above policy per repo.

**Result: 664.3 GB reclaimed, 69.4% of the current 957.7GB registry.** Biggest contributors:
`dagster/user-code/pipeline` 339.5GB, `idp/nexdos_app/backend` 147.1GB,
`dagster/ops/images/nexdos-datalore-agent` 133.4GB (88% of that repo alone). Full per-repo table
and caveats in `nexdos-gitlab-storage-report.md` §6 (same folder) — including the zero-reclaim
cases (e.g. `idp/keycloak/theme`: tags would expire but share all blobs with kept tags, so no space
freed) and the dormant repos untouched by the keep-N floor. Still nothing applied — simulation only.

### Dry-run result (executed 2026-10-12, informational only — no deletion, no maintenance mode used)

```
23597 blobs marked, 0 blobs and 0 manifests eligible for deletion
```

**Current reclaimable space: 0 bytes.** Confirms the expectation above — nothing has been deleted
at the tag/manifest level yet, so every blob on disk is still live/referenced. The full 925GB is
currently "in use" from the registry's own accounting. **To get a non-zero number, something must
be pruned first** (manual tag deletion, or a GitLab Cleanup policy on the high-tag-count repos —
see §3's CI-tag-accumulation note), then this same `--dry-run` re-run will report what that pruning
actually frees up. No backup/readonly-mode decision was needed for this run since dry-run never
writes.

---

## 7. Sources

- [Document how to move from the Docker/Distribution registry to the GitLab container registry (#1557)](https://gitlab.com/gitlab-org/container-registry/-/issues/1557) — open request, no official doc yet; "drop-in" claim + storage-driver caveats.
- [Deprecate: container registry support for storage Drivers OSS and Swift (#1141)](https://gitlab.com/gitlab-org/container-registry/-/issues/1141) — not applicable, nexdos uses filesystem storage.
- [Container registry metadata database: migration on docker installation — GitLab Forum](https://forum.gitlab.com/t/container-registry-metadata-database-migration-on-docker-installation/111263) — real docker-compose precedent, DB-provisioning workaround, 18.3 data-loss warning.
- [Migration of legacy container registry to registry metadata database — GitLab Forum](https://forum.gitlab.com/t/migration-of-legacy-container-registry-to-registry-metadata-database/130880)
- [GitLab container registry administration](https://docs.gitlab.com/administration/packages/container_registry/) — standalone image reference (`registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:vX.Y.Z-gitlab`).
- [Container registry metadata database](https://docs.gitlab.com/administration/packages/container_registry_metadata_database/) — Omnibus-centric, but general requirements (Postgres 12+, keep object storage, never run offline GC after import) still apply.
- Amfileon reference docs (same repo, `../gitlab-registry-config-reference.md`, `../registry-runbook.md`, `../registry-migration-test-plan.md`).
