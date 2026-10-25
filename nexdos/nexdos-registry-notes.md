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

### Cleanup policy enabled on `dagster/user-code/pipeline` — "not working" diagnosis (2026-10-13)

User enabled GitLab's Container Registry Cleanup Policy on this project (keep 25 most recent tags,
remove tags older than 30 days, remove-regex `.*`, no keep-regex) and reported it "not working."

**Diagnosis (all read-only checks, no changes made, GitLab left untouched/live throughout):**
- Re-ran `tag-ages.py`: repo went 720→722 tags (Oct 12→13, grew not shrank), still 333 tags >180
  days old, oldest still 645 days — confirms zero cleanup has occurred.
- `ContainerExpirationPolicy` DB record (via `bundle exec rails runner`, path: `/home/git/gitlab`,
  no `gitlab-rails` wrapper in this non-Omnibus image): `enabled: true`, `keep_n: 25`,
  `older_than: "30d"`, `next_run_at: 2026-10-13 16:50:06 +0200` (=14:50 UTC). `created_at:
  2023-10-05` is just the auto-created default row at project creation (every project gets one,
  typically disabled) — not evidence it ran historically. `updated_at` = Oct 12 16:50:06 is almost
  certainly when the policy was actually enabled/saved — so it's had **zero** due-opportunities yet.
- Sidekiq process: healthy, running (`sidekiq 7.3.9`, 25 concurrency).
- `Sidekiq::Cron::Job` for `container_expiration_policy_worker`: enabled, cron `50 * * * *`
  (hourly), `last_enqueue_time: 08:50 UTC` today — before this policy's 14:50 UTC due time, so it
  hasn't been picked up by any confirmed firing yet.
- `Sidekiq::Cron::Job` for `cleanup_container_registry_worker` (actual tag-delete executor): enabled,
  cron `*/5 * * * *`, `last_enqueue_time: 09:40 UTC` today — firing regularly and recently.

**Conclusion: nothing appears broken.** Both relevant workers are healthy and firing on schedule;
the policy simply hasn't reached its first due window yet (next check: re-run `tag-ages.py` after
~14:50 UTC / 16:50 CEST on 2026-10-13 and compare the `dagster/user-code/pipeline` row).

**Note the live settings differ from the suggested Category A policy** (report §6): `keep_n: 25`
not 10, `older_than: 30d` not 90d, no keep-regex set (vs. the suggested
`main|master|stable|latest|release-.*|vX.Y.Z` pattern) — so actual results, once it does run, will
differ from the simulated 339.5GB/90-day projection for this repo; a 30-day cutoff with no name
protection will likely remove more tags, faster, than the simulation modeled.

### ROOT CAUSE FOUND: cleanup policy stuck due to local port exhaustion (2026-10-13)

Continuing the "not working" diagnosis above — traced through to a definitive, confirmed cause.

**Chain of evidence (all read-only checks, GitLab left live/untouched throughout):**
1. `exceptions_json.log` inside the `gitlab` container showed every registry API call from
   `ContainerExpirationPolicies::CleanupContainerRepositoryWorker` failing with
   `Faraday::ConnectionFailed: Failed to open TCP connection to registry:5000 (Cannot assign
   requested address - connect(2)...)`, `cause_class: Errno::EADDRNOTAVAIL` — across manifest
   fetches, blob fetches, AND the actual tag-delete calls, for multiple repos, with several
   failures sharing the exact same millisecond timestamp (confirms concurrent workers, not one
   stuck request).
2. Ruled out IPv6 misconfiguration: `docker network inspect proxy_network` → `EnableIPv6: false`;
   `getent ahosts registry` → IPv4 only (`172.19.0.20`); a direct `curl` from the gitlab container
   to the registry succeeded instantly (401, as expected unauthenticated) — basic connectivity is
   fine in isolation.
3. Ruled out conntrack exhaustion: `nf_conntrack_count` 362 / `nf_conntrack_max` 262144, no "table
   full" in `dmesg`. (Also conceptually moot — gitlab and registry share the same bridge network,
   so this traffic never needs NAT/conntrack at all.)
4. **Confirmed root cause**: `grep ':1388' /proc/net/tcp` (port 5000 in hex) inside the `gitlab`
   container showed **25,171 sockets stuck in `TIME_WAIT`**, against a local ephemeral port range
   of only `32768–60999` (~28,232 ports total, confirmed standard/default, not misconfigured) —
   i.e. **~89% of the entire available port range consumed by lingering TIME_WAIT connections to
   the registry alone.**

**Mechanism**: every tag the cleanup job touches opens its own short-lived connection (manifest
GET, blob GET for push-date sort, DELETE) rather than reusing a persistent one. With 722+ tags
re-walked every ~5-minute retry cycle (never completing, so it keeps re-attempting the same full
list from scratch), TIME_WAIT sockets accumulated faster than the kernel's ~60s default timeout
could drain them, eventually nearly exhausting the port pool — causing intermittent
`EADDRNOTAVAIL` on new connection attempts, which is why **zero tags have ever actually been
deleted** by this policy despite it actively retrying.

**Fix identified, NOT applied** (user explicitly deferred — GitLab is in active use, no
maintenance window right now): add to the `gitlab` service in `docker-compose.yaml`:
```yaml
sysctls:
  - net.ipv4.tcp_tw_reuse=1
```
Lets the kernel safely reuse TIME_WAIT sockets for new outbound connections — directly relieves
the exhaustion. Requires `docker compose up -d` (container recreate, brief restart) to apply —
revisit when a maintenance window is available. This is a host/container-level fix, unrelated to
the registry's own config (plain `registry:2`) or to the cleanup policy settings themselves.

### Manual verification: deletion confirmed working once port pool is clean (2026-10-13)

Following the root-cause finding above, manually verified the fix hypothesis with a real,
controlled test — **this section involves actual deletions, not read-only checks.**

1. Disabled the cleanup policy (`cep.update!(enabled: false)`, reversible, via `rails runner`) to
   stop the background retry storm. Confirmed `Sidekiq::Workers` went empty and
   `grep -c ':1388' /proc/net/tcp` dropped from 26,439 → **0** within ~1-2 minutes — confirms
   TIME_WAIT entries drain fine on their own once nothing new is piling on.
2. First manual delete attempt (10 oldest tags of `dagster/user-code/pipeline`, by tag **name**)
   returned `deleted=false` for all 10 with a clean port pool — ruled out port exhaustion as the
   cause of *this* result. Root cause: our own test bug — `ContainerRepository#delete_tag`
   requires a **digest**, not a tag name (confirmed by reading
   `app/models/container_repository.rb`: the real `delete_tags!` method always resolves
   `tag.digest` before calling `delete_tag`; we were skipping that step). Not a GitLab bug.
3. Corrected test (resolve each tag to digest first, then `delete_tag(digest)`) — **all 10
   returned `deleted=true`**, confirmed on disk via `tag-ages.py`: `dagster/user-code/pipeline`'s
   oldest tag moved from 645.0d → 615.9d, exactly consistent with the 10 removed (616-645d range).

**Conclusion: deletion mechanism itself works correctly.** The only real blocker is the port
exhaustion (§ above) that prevents the automated policy from completing a full 722-tag pass in
one go. Small/manual batches work fine once the port pool has headroom.

**Open item**: the cleanup policy is currently **disabled** (`enabled: false`) as a side effect of
step 1 above. It was NOT re-enabled as of this note — pending user decision on whether to leave
it off until the `tcp_tw_reuse` fix lands, or re-enable now (next scheduled run isn't until
2026-10-14 12:14, so no immediate retrigger either way).

### FIX APPLIED: tcp_tw_reuse added to gitlab service (2026-10-13)

The root-cause fix identified earlier was applied for real, with user confirmation at each
mutating step:

```yaml
  gitlab:
    ...
    volumes:
    - gitlab-data:/home/git/data:Z
    - certs-data:/certs
    - ./sockets:/var/opt/gitlab/gitlab-kas/sockets/
    # Fix for container registry cleanup policy failures: GitLab's tag-expiration worker opens
    # one short-lived connection per tag (manifest/blob fetch + delete) against the registry
    # container. On repos with hundreds of tags, this exhausted the local ephemeral port range
    # (TIME_WAIT sockets piled up faster than they could drain), causing Faraday::ConnectionFailed
    # / EADDRNOTAVAIL and leaving cleanup policies permanently stuck in cleanup_unfinished.
    # tcp_tw_reuse lets the kernel reuse TIME_WAIT sockets for new outbound connections instead.
    # Diagnosed 2026-10-13, see nexdos-registry-notes.md.
    sysctls:
    - net.ipv4.tcp_tw_reuse=1
    networks:
    - default
    - ldap
```

Process: validated with `docker compose config` + `docker compose up -d --dry-run gitlab` (showed
a clean recreate plan, dependencies untouched) before applying for real. Note: also discovered
mid-process the live image had already been bumped to `sameersbn/gitlab:19.4.1` (from the
`18.11.11` this whole investigation was conducted against) — unrelated to this fix, just a
pre-existing drift between the local reference compose copy and the real host file.

**Applied**: `docker compose up -d gitlab` — container recreated in 7.3s. **Verified**:
`cat /proc/sys/net/ipv4/tcp_tw_reuse` inside the container reads `1`.

**Status**: fix is live. The underlying port-exhaustion bug that caused cleanup policies to get
permanently stuck in `cleanup_unfinished` should no longer occur. Not yet verified at real scale
via the actual cron schedule — worth checking the next scheduled run (`dagster/user-code/pipeline`'s
policy next fires `2026-10-14 12:37:07`) completes cleanly without manual intervention.

**Manual cleanup progress on `dagster/user-code/pipeline` (separate from the fix above)**: 360
tags deleted across four verified manual batches (10 + 50 + 100 + 200, all via direct
`delete_tag(digest)` calls, 0 failures) before switching back to the automated policy. 339 tags
(oldest, excluding the 25 most recent) were prepared in a final batch but not executed — the
policy was re-enabled instead and will pick up the remainder on its next scheduled run.

### REAL GARBAGE COLLECTION RUN — 212GB reclaimed (2026-10-13)

Timed dry-run first to size the readonly-mode risk precisely: **1.17 seconds** for the full mark
phase (much faster than originally estimated, since the registry is now smaller post-tag-deletion).
At that duration, estimated risk of a concurrent push landing in the window (using the observed
~9 tags/day system-wide push rate): **~0.012%** — judged negligible, so the real run was executed
**without** readonly mode (user's informed call, accepted the small residual risk rather than taking
the extra `docker compose up -d registry` recreate).

```bash
time sudo docker exec registry registry garbage-collect /etc/docker/registry/config.yml
```

No errors, completed cleanly. **Verified via `du -sh` on the registry volume:**

| | Size |
|---|---|
| Before (baseline, §6) | 957.7 GB |
| After real GC | **746 GB** |
| **Reclaimed** | **~212 GB** |

This is a measured, real result — not a projection. Combined with the earlier manual tag deletions
(360 tags from `dagster/user-code/pipeline`) and the `tcp_tw_reuse` fix now live, this closes out
the full chain: port-exhaustion root cause → fixed → tags deletable again → GC reclaims the space.

### ROOT CAUSE #2: cleanup policy structurally cannot work with this registry setup (2026-10-13 to 2026-10-16)

Separate, deeper issue found AFTER the port-exhaustion fix (§ above) was applied and verified. Even
with the port bug fixed, the policy completes "cleanly" every run but deletes **zero** real tags.
Traced to source, then confirmed against official docs — fully verifiable, links below.

#### Evidence 1 — `sameersbn/gitlab` has never bundled a registry, at any version

Confirmed via direct research against the current, actively-maintained `19.x` line (as of
2026-10-16, latest tag `19.5.0`):
- [`docs/container_registry.md`](https://github.com/sameersbn/docker-gitlab/blob/master/docs/container_registry.md)
  — their own documented setup uses a **separate `registry:2` container**, exactly the pattern
  nexdos runs. Quote: *"The example below uses `registry:2` to avoid issues in validating the token."*
- [`Dockerfile`](https://github.com/sameersbn/docker-gitlab/blob/master/Dockerfile) and
  `assets/build/install.sh` — zero registry-related build/install steps. Only GitLab FOSS,
  gitlab-shell, gitlab-workhorse, gitlab-pages, gitaly get built.
- [Docker Hub tags](https://hub.docker.com/r/sameersbn/gitlab/tags) — confirms `19.4.1` (Sept 2026)
  and `19.5.0` (Oct 2026) both exist, so this is current data, not stale/outdated research.
- **Contrast**: official Omnibus `gitlab-ce` bundles GitLab's *own fork* of the registry
  (`gitlab-org/container-registry`) as a supervised process in the same container, with Postgres
  metadata-DB/online-GC support. `sameersbn/gitlab` has never included this, at any version.

#### Evidence 2 — GitLab's own docs say third-party registry support (what you get instead) is unreliable/deprecated

- [Reduce container registry storage](https://docs.gitlab.com/user/packages/container_registry/reduce_container_registry_storage/):
  *"GitLab Self-Managed supports third-party registries that comply with the Docker Registry HTTP
  API V2 specification, but this specification does not include a tag delete operation. GitLab
  therefore uses a workaround, and **this workaround is not guaranteed to work with all
  third-party registries in the same predictable way.** With the GitLab Container Registry, this
  workaround is not required, so cleanup policies are consistent and predictable."*
- [GitLab container registry administration](https://docs.gitlab.com/administration/packages/container_registry/):
  *"Using third-party container registries in GitLab is deprecated and no longer supported."*
  *"The integration is not disabled, but support for debugging and fixing issues is no longer
  provided."* *"The integration is no longer being developed or enhanced with new features."*

#### Evidence 3 — the exact failing code, read directly off this running system (most authoritative — not a quote from elsewhere, this is nexdos's actual `19.4.1` source)

`lib/container_registry/client.rb` (`supports_tag_delete?`, full method, via
`docker exec gitlab sed -n '80,110p' .../client.rb`):
```ruby
# Check if the registry supports tag deletion. This is only supported by the
# GitLab registry fork. The fastest and safest way to check this is to send
# an OPTIONS request to /v2/<name>/manifests/<tag>, using a random
# repository name and tag (the registry won't check if they exist).
# Registries that support tag deletion will reply with a 200 OK and include
# the DELETE method in the Allow header. Others reply with an 404 Not Found.
def supports_tag_delete?
  strong_memoize(:supports_tag_delete) do
    registry_features = Gitlab::CurrentSettings.container_registry_features || []
    next true if ::Gitlab.com_except_jh? && registry_features.include?(REGISTRY_TAG_DELETE_FEATURE)

    response = faraday.run_request(:options, '/v2/name/manifests/tag', '', {})
    response.success? && response.headers['allow']&.include?('DELETE')
  end
end
```
Confirmed on nexdos: this returns **`true`** for the plain `registry:2` backend — a false positive.
`registry:2`'s router advertises `DELETE` in the `Allow` header generically (because
`REGISTRY_STORAGE_DELETE_ENABLED=true` really does enable the verb on that route), which this
heuristic misreads as "this is GitLab's fork." It cannot distinguish "DELETE works for this route
pattern" from "DELETE works specifically when given a tag name instead of a digest."

`app/services/projects/container_repository/gitlab/delete_tags_service.rb` (full file, confirmed
on nexdos) — the path taken because of the false positive above:
```ruby
# Delete tags by name with a single DELETE request. This is only supported
# by the GitLab Container Registry fork. See
# https://gitlab.com/gitlab-org/gitlab/-/merge_requests/23325 for details.
def delete_tags
  tag_names.each do |name|
    if container_repository.delete_tag(name)   # <- passes the TAG NAME, not a digest
      deleted_tags.append(name)
    end
  end
  deleted_tags.any? ? success(deleted: deleted_tags) : error(...)
end
```

`lib/container_registry/base_client.rb` (`delete_if_exists`, confirmed on nexdos via WebFetch of
the public GitLab source, matches the behavior observed):
```ruby
def delete_if_exists(path)
  result = faraday.delete(path)
  result.success? || result.status == 404
end
```
**A 404 counts as success.** Since the tag name isn't a valid digest, the registry correctly
responds 404 ("no manifest with that digest") — and this code treats that as "already deleted,
fine." Every one of the 159 tags in a real run (`dagster/user-code/pipeline`, 2026-10-15) got
`deleted_tags.append(name)`, the job logged a clean success, and **zero bytes on disk ever changed.**

This was independently verified by accident earlier: calling `delete_tag` with a placeholder string
(`'PASTE_TAG_NAME_HERE'`, not a real tag) also returned `true` — the exact same 404-as-success
trap, just triggered manually instead of by the automated worker.

#### Confirmed against the exact installed version, not just generic/latest docs

`sameersbn/gitlab:19.4.1`'s `assets/build/install.sh` clones
`https://gitlab.com/gitlab-org/gitlab-foss.git` at tag `v19.4.1` — `gitlab-foss` is the direct
continuation of what used to be named `gitlab-ce` (renamed years ago when GitLab split fully-free
code from the EE-licensed main repo). So this is genuine, official GitLab CE source at the exact
installed version, not an unofficial fork — and the version-**pinned** docs (not the
always-current page) carry the identical caveats:
- [docs.gitlab.com/19.4/administration/packages/container_registry/](https://docs.gitlab.com/19.4/administration/packages/container_registry/) — *"Using third-party container registries in GitLab is deprecated and no longer supported."*
- [docs.gitlab.com/19.4/user/packages/container_registry/reduce_container_registry_storage/](https://docs.gitlab.com/19.4/user/packages/container_registry/reduce_container_registry_storage/) — *"this workaround is not guaranteed to work with all third-party registries in the same predictable way."*

Base image reference (unrelated to the bug, just for completeness): `sameersbn/gitlab:19.4.1`
builds on `ubuntu:noble-20260917` (Ubuntu 24.04), with `GITALY_SERVER_VERSION`/`GITLAB_PAGES_VERSION`
pinned to the same `19.4.1`/`19.5.0`-style version numbers as the GitLab source itself.

#### Why this isn't as nonsensical as it feels

`sameersbn/gitlab` predates (or simply never adopted) GitLab's own registry-fork project — it was
built around the plain, upstream Docker/Distribution registry from the start, which is a
completely reasonable, supported combination **for basic registry use** (push/pull/auth all work
fine, confirmed throughout this whole investigation). The breakage is specific and narrow: GitLab's
*cleanup-policy automation* added a capability-detection shortcut years ago that assumes "DELETE
is advertised → must be our fork," which happens to misfire against any plain registry that has
deletion enabled (a very normal, common setting). GitLab's own docs now call third-party registry
support deprecated — not because basic registry functionality broke, but because GitLab stopped
investing in edge cases like this one as they consolidated around their own fork. It's less "this
combination was never meant to work" and more "the automation layer bit-rotted while the base
functionality kept working," which is why the manual digest-based approach we proved repeatedly
today still works perfectly — it just bypasses the broken capability-detection shortcut entirely.

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

## 7. Migration to Omnibus `gitlab-ce` — working notes (2026-10-25)

Direction taken: §4 **Option B**, move the whole instance to Omnibus `gitlab/gitlab-ce` (bundled GitLab registry
fork + metadata DB). Root cause #2 (§6) means cleanup policies can't work on `registry:2` at all, and GitLab calls
third-party registry support deprecated; Omnibus is the supported setup. Operating instructions and the cutover
runbook live in [`gitlab-ce/README.md`](gitlab-ce/README.md) (also on the host as `/srv/docker/gitlab-ce/README.md`).

### What runs now

- **New instance** `gitlab-ce` (compose project + container), folder `/srv/docker/gitlab-ce`, root-owned like
  `/srv/docker/gitlab`. Volumes `gitlab-ce_config/_logs/_data` + `gitlab-ce-registry` — never shared with the
  old `gitlab_*` volumes. Test URLs git-staging.nexdos.de / registry-staging.nexdos.de (wildcard DNS, cert issued
  automatically by the host's nginx-proxy + Let's Encrypt companion), SSH 20022 (firewalled from outside —
  only reachable on the host itself).
- **Contents**: full copy of production from the 2026-10-25 01:00 nightly backup, incl. all registry images
  (~306GB copied + imported), with `SANITIZE=true` (cleanup policies, schedules etc. disabled, "TEST COPY"
  banner, email off). The three cleanup policies were then re-enabled on the copy only, to watch them delete.
- **Production untouched** throughout: the restore used an existing nightly backup copied by hand, secrets and
  counts were only read. A safety copy of that backup + `secrets.yml` + production compose file is in
  `/home/ssa/gitlab-backup-safety` (same disk — protects against deletion, not disk loss).

### Files (local: `gitlab-ce/`)

| File | Purpose |
|---|---|
| `docker-compose.yaml`, `.env.example` | The instance; every setting/secret in `.env` (gitignored). |
| `import-prod-env.sh` | Fills `.env` from the running prod container (LDAP, SMTP, version); adds new settings to old `.env` files. |
| `clone-from-prod.sh` | Backup → secrets → restore → optional sanitize → optional registry copy + import → verify. Switches `USE_EXISTING_BACKUP`, `SKIP_REGISTRY`, `SANITIZE`. |
| `backup.sh` | Nightly backup after cutover (`SKIP=registry` + `/etc/gitlab`). |

Rehearsal at the real version: `migration-rehearsal/rehearsal-19.5.0/` (sameersbn 19.5.0 + registry:2 → gitlab-ce
19.5.0, seeded with `seed.rb`; run logs `run1`–`run4`). The older 19.4.1 rehearsal in `migration-rehearsal/` is superseded.

### Verified

- Rehearsal: restore, secrets (encrypted CI variable decrypts, `gitlab:doctor:secrets` clean), passwords, git
  clone, sanitize; registry import + pull; a tag deleted via `DeleteTagsService` is **really gone** on the new
  registry (the exact thing that silently no-op'd on `registry:2`); existing-backup mode leaves prod's backup dir
  byte-identical.
- On nexdos: restore with 0 errors; 47 users / 64 projects / 26 container repos (prod 48 / 65 / 26 — created
  after the 01:00 backup); registry import 0 errors, `supports_gitlab_api?: true`, tags visible; SSH host keys
  copied, RSA/ECDSA/ED25519 fingerprints identical to prod's port 10022; SMTP config accepted (email still off).

### Findings worth remembering

- Production's image tag is `sameersbn/gitlab:latest`; it was at **19.5.0**, not the 19.4.1 these notes assumed.
  Watchtower is `WATCHTOWER_MONITOR_ONLY` — it doesn't upgrade anything, so version drift only comes from manual
  pulls. The clone script compares the real versions (`VERSION` files) and refuses on a mismatch.
- `gitlab:doctor:secrets` shows **15 undecryptable rows identically on prod and the copy**: 14 legacy OTP rows
  (old column; real `User` OTP secrets decrypt fine) and `DependencyProxy::GroupSetting[1]` identity/secret —
  pre-existing, not caused by the migration. The alternating 801/2414-byte `secrets.yml.orig.*` files are normal
  sameersbn startup behaviour (reproduced in the rehearsal).
- Security keys / passkeys (WebAuthn) don't work on the test URL — bound to git.nexdos.de; fine after cutover.
- Enabled cleanup policies on prod: `idp/nexdos_app` (keep 100, >90d), `dagster/user-code/pipeline` (keep 25,
  >30d), `homepage/nexdos` (keep 5, >14d); none has a keep-regex. They come over enabled and will really delete.
  No Kubernetes agents (KAS needs no config).
- Fresh 19.5.0 installs (rehearsal only) need Postgres `max_locks_per_transaction` > 64 and reject weak admin
  passwords — irrelevant for nexdos itself, whose database already exists.
- World-readable on the host (not changed, by choice): `/srv/docker/gitlab/docker-compose.yml(.save)` with all
  production secrets, `gitlab-pg14-dumpall.sql` (full DB dump), `gitlab_postgresql-data.tar.gz`,
  `/srv/docker/gitlab-runner/config.toml` (runner tokens).

### Registry cleanup that made the copy possible

Tag deletion by digest + offline GC on the old `registry:2`: 957.7GB → 309GB (682GB reclaimed in four GC runs,
1,901 tags deleted). Host disk afterwards: 873GB free, 561GB after the registry copy.

### Left

Decide keep-regexes for the three policies; pick a maintenance window (~1h); cutover per the README runbook;
afterwards backup cron, off-host backup for the registry volume, remove old volumes after ~2 weeks.

---

## 8. Sources

- [Document how to move from the Docker/Distribution registry to the GitLab container registry (#1557)](https://gitlab.com/gitlab-org/container-registry/-/issues/1557) — open request, no official doc yet; "drop-in" claim + storage-driver caveats.
- [Deprecate: container registry support for storage Drivers OSS and Swift (#1141)](https://gitlab.com/gitlab-org/container-registry/-/issues/1141) — not applicable, nexdos uses filesystem storage.
- [Container registry metadata database: migration on docker installation — GitLab Forum](https://forum.gitlab.com/t/container-registry-metadata-database-migration-on-docker-installation/111263) — real docker-compose precedent, DB-provisioning workaround, 18.3 data-loss warning.
- [Migration of legacy container registry to registry metadata database — GitLab Forum](https://forum.gitlab.com/t/migration-of-legacy-container-registry-to-registry-metadata-database/130880)
- [GitLab container registry administration](https://docs.gitlab.com/administration/packages/container_registry/) — standalone image reference (`registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:vX.Y.Z-gitlab`).
- [Container registry metadata database](https://docs.gitlab.com/administration/packages/container_registry_metadata_database/) — Omnibus-centric, but general requirements (Postgres 12+, keep object storage, never run offline GC after import) still apply.
- Amfileon reference docs (same repo, `../gitlab-registry-config-reference.md`, `../registry-runbook.md`, `../registry-migration-test-plan.md`).
