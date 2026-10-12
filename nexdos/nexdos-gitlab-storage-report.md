# nexdos GitLab — Storage Report

**Date:** 2026-10-12
**Scope:** GitLab's storage footprint on the nexdos host — why it's large, where the bloat
actually lives, and recommended cleanup policies. Everything below is from read-only analysis;
no tags, images, or data have been deleted or modified.

---

## 1. Executive summary

GitLab's total footprint on nexdos is ~1TB. **97.8% of it is the container registry**, not git
repos or the database. Within the registry, **73% of all storage (859GB) sits in just 3 of 24
repositories** — and in those same repos, **44–93% of tags are over 180 days old**, left over from
CI builds with no retention policy ever applied. The fix is a standard GitLab Cleanup Policy, not
an infrastructure change. A tag-level simulation against the real manifest data (§6) projects
**664.3GB reclaimed — 69.4% of the registry's current 957.7GB** — once the proposed policies are
fully rolled out.

---

## 2. GitLab setup overview (nexdos)

- **GitLab app**: `sameersbn/gitlab:18.11.11` — a from-source (non-Omnibus) build. No `gitlab-ctl`,
  no `/etc/gitlab/gitlab.rb`; configuration is via flat `GITLAB_*`/`DB_*`/`LDAP_*`/`SMTP_*` env vars,
  plus a narrow custom parser that additionally understands `GITLAB_OMNIBUS_CONFIG`-style
  `gitlab_kas[...]` directives (added just to support GitLab KAS, not a general Omnibus interpreter).
- **Container registry**: a **separate container**, plain upstream `registry:2` (confirmed
  `docker/distribution 2.8.3`, no `database` subcommand) — not GitLab's own forked registry binary
  that Omnibus installs. JWT auth between the two is wired via a shared `certs-data` volume
  (`GITLAB_REGISTRY_GENERATE_INTERNAL_CERTIFICATES=true`), issuer `gitlab-issuer`.
- **Supporting services**: `sameersbn/postgresql:14` (GitLab's rails DB), `redis:6.2.6`.
- This is one of several unrelated services sharing the host (JupyterHub, a standalone Postgres,
  Sentry, Uptime-Kuma, SuiteCRM, WordPress, LDAP, MinIO, etc.) — see §3.

Because the registry here is the plain/vanilla upstream binary rather than GitLab's fork, the
**metadata-database / online garbage-collection feature does not exist on this registry** —
that capability is exclusive to GitLab's own fork (`gitlab-org/container-registry`), which was
never upstreamed. Garbage collection here is the classic **offline** mark-and-sweep
(`registry garbage-collect`), which only reclaims blobs that are *already* orphaned by a prior
tag/manifest deletion — it has no retention logic of its own.

---

## 3. Host-level storage context

Total disk usage: 2.7T used / 659G free (81%) on `/dev/md2` (3.5T). GitLab is one of several large
consumers on this host:

| Consumer | Size | Notes |
|---|---|---|
| `gitlab_registry-data` | 979–984G | The registry — see §4 |
| JupyterHub (`jupyterhub-shared` etc.) | 540G | Unrelated to GitLab |
| Standalone `postgres` volume | 324G | Unrelated to GitLab's own DB |
| `/srv/data/minio` | 565G | Separate S3-compatible object storage, unrelated |
| `gitlab_gitlab-data` (real repos+backups+uploads) | 19G | Only 1.2G is actual git repo content; 16G is accumulated backup tarballs with no visible retention limit |
| `gitlab_postgresql-data` (rails DB) | 3.0G | Trivial |
| ~14 anonymous volumes matching sameersbn's internal layout | ~63G | Appear to be orphaned/abandoned test GitLab instances — not confirmed whether still attached to a running container |

**Takeaway**: GitLab's own application data (code, database) is negligible. The entire "GitLab is
big" problem is a registry problem.

---

## 4. Registry findings

### 4.1 Overall

- Total registry size: **~979–984GB**, 24 repositories, 3,228 tags, ~23,600 blobs.
- A `registry garbage-collect --dry-run` run on 2026-10-12 found **0 blobs and 0 manifests eligible
  for deletion** — every byte is currently referenced by a live tag. GC cannot help until tags are
  actually pruned first; it has no age/count policy of its own.

### 4.2 Storage concentration

Built by cross-referencing the dry-run's per-repo blob references against real on-disk blob sizes
(exclusive = what would be freed if that repo alone were emptied):

| Repo | Exclusive GB | % of total | Tags |
|---|---|---|---|
| `dagster/user-code/pipeline` | 470.4 | 48% | 720 |
| `idp/nexdos_app/backend` | 237.9 | 25% | 620 |
| `dagster/ops/images/nexdos-datalore-agent` | 151.2 | 16% | 108 |
| *(all 21 remaining repos combined, incl. every `/cache` repo)* | ~111 | 11% | ~1,780 |

Almost no cross-repo layer sharing in the top repos (inclusive ≈ exclusive) — each CI build is
producing largely unique layers, so pruning old tags translates almost 1:1 into reclaimed space.

### 4.3 Tag age distribution

Using each tag's on-disk `current/link` mtime as a "last pushed" proxy:

| Repo | Tags | >180 days old | Newest tag |
|---|---|---|---|
| `dagster/user-code/pipeline` | 720 | 323 (45%), oldest 644d | 2.9d (active) |
| `idp/nexdos_app/backend` | 620 | 273 (44%), oldest 283d | 1.8d (active) |
| `dagster/ops/images/nexdos-datalore-agent` | 108 | 100 (93%!), oldest 1,053d | 46.6d (barely active) |
| `idp/nexdos_app/frontend/cache` | 426 | 277 (65%), oldest 489d | 1.8d |

**~14 repos are dormant** — not just old on average, but the *newest* tag itself is months to years
old (e.g. `dagster/pipeline-example`: newest tag 1,108 days old; `dataflow/airbyte_poc`: 1,526
days). A retention policy's "keep most recent N" floor won't clean these up — nothing new arrives
to push the window forward. These need a manual "is this project still needed" decision, not an
automated expiry rule.

---

## 5. Root cause

No tag retention has ever been applied. CI pushes a new, mostly-unique-layer image per build and
nothing ever expires old ones — confirmed by the near-zero layer sharing in the big repos and the
heavy >180-day backlog. The `/cache` repos compound this: 400–900+ tags each suggests CI is pushing
a new uniquely-named cache image per run instead of overwriting one stable `:cache` tag, so they
accumulate indefinitely rather than functioning as a rotating build cache.

---

## 6. Recommended policies

**A — Active high-storage repos** (`dagster/user-code/pipeline`, `idp/nexdos_app/backend`,
`dagster/ops/images/nexdos-datalore-agent`):
- Keep most recent: **10 tags**
- Expire tags older than: **90 days**
- Preserve (regex): `^(main|master|stable|latest|release-.*|v[0-9]+\.[0-9]+\.[0-9]+)$`
- Remove (regex): `.*`
- **Projected savings: ~620.0 GB** (339.5 + 147.1 + 133.4 GB across the three repos — 93% of the
  total projected reclaim comes from this one category)

**B — Cache repos** (`*/cache`, excluding the two dormant ones already covered under D):
- Keep most recent: **2–3 tags**
- Expire tags older than: **7 days**
- No preserve pattern needed
- **Root-cause fix (separate from the policy)**: change CI to push to one stable, overwritten
  `:cache` tag instead of a unique tag per run — stops the accumulation at the source.
- **Projected savings: ~30.1 GB** (`idp/nexdos_web/cache` 15.0 + `idp/nexdos_app/frontend/cache`
  8.8 + `idp/nexdos_app/backend/cache` 6.3 GB)

**C — Small/low-churn repos** (everything else still receiving pushes):
- Keep most recent: **25 tags**
- Expire tags older than: **90 days**
- Same preserve regex as Category A
- **Projected savings: ~11.9 GB** — mostly `dagster/user-code/dash-app` (6.3GB) and `idp/nexdos_web`
  (3.9GB); several repos in this category (e.g. `idp/keycloak/theme`) project **0GB** despite tags
  expiring, since those tags share all their blobs with tags that would be kept

**D — Dormant repos** (newest tag itself is months/years old, e.g. `dagster/pipeline-example`,
`idp/nexdos_k8s_app/frontend`, `dataflow/airbyte_poc`, 12 repos total):
- Not a cleanup-policy case. Needs a manual decision: is the project still needed at all? If not,
  consider removing the repo/project entirely rather than tuning an expiry window for it.
- **Projected savings if policy applied anyway: ~2.3 GB** — negligible, because most of these
  repos have fewer tags than any reasonable keep-N floor, so nothing would actually expire; the
  small amount that does come from just 2 of the 12 repos. Confirms this category needs a business
  decision, not a retention-policy tweak — there's essentially nothing to reclaim here mechanically.

**Total across all four categories: 664.3 GB — matches the registry-wide simulation in §6 below.**

### Rollout caution

GitLab's cleanup policy applies **retroactively** the moment it runs — there is no built-in dry-run
in GitLab CE. Recommended sequence:
1. Enable on **one repo first** (`idp/nexdos_app/backend` suggested — second-biggest, slightly
   lower-stakes than the main pipeline).
2. Let it run once, verify the resulting tag count and that nothing important vanished.
3. Roll out to `dagster/user-code/pipeline`, `nexdos-datalore-agent`, then the cache/small repos.

### Projected reclaim (simulated 2026-10-12, not yet applied)

Computed by reading every tag's actual manifest (exact blob/layer digests, not an approximation),
applying the keep-N + age-threshold + preserve-regex rule above per repo, and summing blobs that
would become orphaned (referenced only by tags that would expire, not by anything kept):

| Repo | Tags | Would expire | Would keep | Reclaim |
|---|---|---|---|---|
| `dagster/user-code/pipeline` | 720 | 507 | 213 | **339.5 GB** |
| `idp/nexdos_app/backend` | 620 | 395 | 225 | **147.1 GB** |
| `dagster/ops/images/nexdos-datalore-agent` | 108 | 98 | 10 | **133.4 GB** (88% of this repo) |
| `idp/nexdos_web/cache` | 201 | 195 | 6 | 15.0 GB |
| `idp/nexdos_app/frontend/cache` | 426 | 417 | 9 | 8.8 GB |
| `dagster/user-code/dash-app` | 47 | 22 | 25 | 6.3 GB |
| `idp/nexdos_app/backend/cache` | 71 | 57 | 14 | 6.3 GB |
| `idp/nexdos_web` | 167 | 83 | 84 | 3.9 GB |
| *(remaining repos, incl. all dormant/untouched ones)* | — | — | — | ~3.4 GB combined |

**Total: 664.3 GB reclaimed, i.e. 69.4% of the current 957.7GB registry.**

Notable zero-reclaim cases: several repos show tags marked "would expire" but 0GB reclaimed
(e.g. `idp/keycloak/theme`: 27 of 52 tags would expire, 0GB freed) — those tags share all their
blobs with tags that would be kept (high layer reuse, e.g. a slowly-changing theme image), so
expiring them cleans up tag-list clutter but frees no disk space. Dormant repos under the keep-25
floor (`idp/nexdos_k8s_app/frontend`, `dagster/user-code/market-data-pipeline`, etc.) show 0
expired tags — the count floor alone protects everything in them, confirming they need the manual
"still needed?" review from §4.3/Category D rather than policy tuning.

---

## 7. Status as of this report

- **Nothing has been deleted, expired, or changed.** All analysis above is read-only.
- No cleanup policy has been enabled yet — §6 is a suggestion pending the user's decision.
- No backup of the registry volume exists (925–984GB doesn't fit in the 248–659GB historically
  available free space on this host) — if a cleanup policy is enabled, there is no full-volume
  rollback path; the dry-run review before each real GC pass is the primary safety net.

---

## 8. Supporting material

- Working notes / chronological log: `nexdos-registry-notes.md` (same folder)
- Scripts: `storage-analysis.py`, `tag-ages.py` (`/Users/sandipsah/Desktop/infrafin/nexdos/`)
- Raw data: `tag-ages-summary-2026-10-12.txt`, `volumes-breakdown-2026-10-12.txt`,
  `output.tx` (raw dry-run log) (same folder)
