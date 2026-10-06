# Compose Sanitization Checklist

Goal for "done": the real `docker-compose.yaml` itself (not a separate `.sanitized`
twin) has every secret field replaced with a `${VAR}` reference, the true original is
preserved as `docker-compose.yaml.pre-versioning-backup`, a `.env` holds the real
values, and `docker compose config` validates clean with no unresolved-variable
warnings.

**db2 re-sweep done** (full tool-fixed re-run against every already-converted service,
after both the same-indentation YAML list bug and the `_PASS` keyword gap were found
and fixed via `gitlab` on db1). 4 services found with missed vars — **user will patch
these later**, marked below with 🔧:
- `clickhouse-marketdata-staging` — 1 new var
- `clickhouse-production` — 1 new var
- `clickhouse-staging` — 1 new var
- `postgres` — 2 new vars
All others on db2 (`clickhouse-external`, `gitlab-runner`, `minio`, `nginx-lb`, `proxy`,
`redis-staging`, `restic`, `restic-restore`, `rustfs`, `watchtower`, and `_archiv`'s
`gitlab-ee`/`gitlab2`/`patroni`) came back clean — no new vars found.

## db2 — live services

- [x] clickhouse-external — converted & validated; "Recreated" confirmed pre-existing (predates our change)
- [x] clickhouse-marketdata-production — converted & validated; "Recreated" confirmed pre-existing (predates our change); `chproxy.yml`/`config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern
- [x] clickhouse-marketdata-staging — converted & validated; `VIRTUAL_HOST_2`/`VIRTUAL_PORT_2` disambiguation (from the minio fix) worked automatically; "Recreated" confirmed pre-existing; `chproxy.yml`/`config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern. **Patched** (`cea41c3`): `SSL_CERT_FILE` had been missed (a `_CERT_FILE`-keyword false positive, confirmed via length check — 19 chars, a path not real cert content), now extracted; "Recreated" re-confirmed pre-existing.
- [x] clickhouse-production — converted & validated; "Recreated" confirmed pre-existing (predates our change); `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern. **Patched** (`cea41c3`): `VIRTUAL_PORT` had been missed (config, not secret), now extracted; "Recreated" re-confirmed pre-existing.
- [x] clickhouse-staging — converted & validated; "Recreated" confirmed pre-existing (predates our change); `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern. **Patched** (`cea41c3`): `VIRTUAL_PORT` had been missed (config, not secret), now extracted; "Recreated" re-confirmed pre-existing.
- [x] gitlab-runner — `docker-compose.yaml` converted & validated (`docker compose up -d --dry-run` confirmed no change vs. running container); `config.toml`/`uv.toml` stay on the old pattern
- [x] minio — converted & validated after finding & fixing two real tool bugs plus one pre-existing production issue (see below); `ldap.env`/`nginx-console.conf` stay on the old pattern
- [x] nginx-lb — converted & validated, no change vs. running containers
- [x] postgres — converted & validated; `postgres-develop`'s "Recreated" confirmed pre-existing (predates our change). **Patched** (`cea41c3`): `VIRTUAL_HOST`/`VIRTUAL_POST` had been missed (config, not secrets), now extracted; `postgres-develop`'s "Recreated" re-confirmed pre-existing.
- [x] proxy — converted & validated; found & fixed a real tool bug along the way (see below)
- [x] redis-staging — converted & validated, no change vs running containers; `redis.conf`/`sentinel.conf` stay on the old pattern
- [x] restic — converted & validated (validation needed both `docker-compose.yaml` + `docker-compose.override.yaml` together, since restic has an override file); `POST_COMMANDS_SUCCESS` block (healthchecks-ping UUID) still deferred per earlier decision
- [x] restic-restore — converted & validated; pre-existing image-drift recreate-need confirmed unrelated to our change (predates it, same as `rustfs`)
- [x] rustfs — converted & validated; `nginx-console.conf`'s redactions stay on the old pattern
- [x] watchtower — converted & validated, existing `.env` appended (not overwritten)

**Real bug found & fixed in the tool** (`proxy`): a Docker volume bind-mount line (`- ./htpasswd:/etc/nginx/htpasswd`) got corrupted into `- ./htpasswd:REDACTED` because `htpasswd` contains `passwd` as a substring with no separator, and the keyword regex had no word-boundary check. This wasn't just over-redaction — it would have broken nginx's basic-auth mount for real. Caught via `docker compose up -d --dry-run` disagreeing with the untouched original file (a discrepancy the two `restic*`/`rustfs` cases turned out NOT to have — those were pre-existing image-drift, unrelated). Fixed in `sanitize_service_files.py` and the pre-commit hook (masks the whole word `htpasswd` before keyword matching), deployed to both hosts.

**Validation gotcha learned**: for a service with a `docker-compose.override.yaml`, always validate with both files together (`docker compose -f docker-compose.yaml -f docker-compose.override.yaml ...`, or no explicit `-f` at all) — passing only `-f docker-compose.yaml` produces a false "Recreated" prediction that has nothing to do with the conversion.

**Two more real bugs found & fixed on `minio`:**
1. **Same key, different value, two services** — `VIRTUAL_HOST`/`VIRTUAL_PORT` are defined independently in both `minio-s3-1` and `minio-nginx` with genuinely different values. Since Docker Compose's `${VAR}` substitution is file-wide (not per-service), extracting both to the same `.env` entry meant one service's value silently overwrote the other's. Fixed in `extract_compose_environment`: a later occurrence of an already-seen key with a different value now gets a disambiguated *source* name (`VIRTUAL_HOST_2`), while the actual environment variable name on the left (what the container/nginx-proxy actually reads) stays unchanged. Deployed to both hosts.
2. **Pre-existing production issue, not caused by today's work**: `minio`'s real `docker-compose.yaml` already had `MINIO_ROOT_PASSWORD: REDACTED` hardcoded as a bare literal (not even a `${VAR}` reference) *before* we ever touched it — almost certainly a leftover from much earlier work in this project. Confirmed via the running container's actual baked-in environment (the real 16-character password only existed there, nowhere in any file) and fixed directly. Worth keeping in mind that other already-committed services could have similar leftover corruption from past sessions — the `docker compose up -d --dry-run` check is what catches this class of issue, so it's worth doing on every service going forward, not just the ones we're actively converting today.

Out of scope: `dockprom`, `zulip` (own nested .git), `gittlab-runner` (stale typo
duplicate, no compose file), `pg-cluster-instance-2` (live HA cluster, handled by
hand).

## db2 — `_archiv/` (test bed)

- [x] gitlab-ee — converted & validated, no REDACTED left
- [x] gitlab2 — converted & validated, no REDACTED left
- [x] gitlab-registry-2 — already used `${VAR}` natively, zero redactions needed
- [x] patroni — converted & validated (5 `ETCD_..._CERT_...` vars flagged secret by keyword were confirmed false positives — booleans/paths, not actual secrets)
- [x] clickhouse-external-old — stale duplicate, already excluded from git via the `*-old/` rule regardless of content
- [x] ntp — not a compose service (just check-ntp.sh + its log), no candidate here
- [x] infisical — empty directory, nothing to do
- [x] gittlab-runner — only a stray `uv.toml`, no compose file, not a candidate

## db1 — live services

Note: `.env.example` also built for the 15 additional services converted later this
session (aws-s3-upload, devpi, flame, grafana-agent, grafana-loki, ldap, mongo,
mongo-production, netboot, patroni, registry, samba-backup, uptime-kuma, xpressfeed,
yopass) — committed & pushed.

Note: `.env.example` built for all 14 services with a real `.env` (gitlab-ee, nginx-lb,
authentik, watchtower, restic, restic-restore, rustfs, minio, redis-staging, postgres,
clickhouse-external, clickhouse-staging, clickhouse-production, clickhouse,
redis-production) — committed & pushed. Also fixed the same `.env.*` / `.env.example`
gitignore gap here that was found on db2 (deferred earlier in this session, now closed).

- [x] authentik — `docker-compose.yaml` converted to working `${VAR}`+`.env`; `docker-compose.override.yml` stays real/untouched (loaded live by Compose) with its `.sanitized` REDACTED twin tracked instead; "Recreated" on 3 containers confirmed pre-existing (matches untouched `.pre-versioning-backup`); committed & pushed (`cfecbe5`)
- [x] aws-s3-upload — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); `credentials` stays on old pattern. **Found & fixed a real tool bug**: an unindented commented-out duplicate line inside `environment:` (e.g. `#      S3_BUCKET: ...` flush at column 0) was misread as ending the block, silently stopping `${VAR}` extraction for every real line after it — `S3_BUCKET`/`DESTINATION_PATH` were left with real literal values untouched in the `.sanitized` twin, and `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` only got a REDACTED fallback (would have broken real S3 auth if swapped in as-is). Fixed in `sanitize_service_files.py` (comment lines now get the same block-boundary exemption blank lines already had), deployed to both hosts (`1d9a3403da8d35ff818eb858c70af0e5`); committed & pushed (`1df14c0`)
- [x] devpi — converted & validated; "Recreated" on `devpi-nginx` confirmed pre-existing; `nginx.conf` stays on old pattern; committed & pushed (`1df14c0`)
- [x] docker-rclone-sync — out of scope, own nested `.git` repo (excluded wholesale in root `.gitignore`), not a candidate for this workflow
- [x] filebeat — nothing to do, already clean and already tracked as-is (0 redactions in both `docker-compose.yml` and `filebeat.yml`)
- [x] flame — converted & validated; "Recreated" confirmed pre-existing (unrelated `version:` obsolete-attribute warning, harmless); committed & pushed (`1df14c0`)
- [ ] gitlab — **major incident, resolved**: the already-committed `docker-compose.yml.sanitized` and `old_gitlab_container_settings.txt.sanitized` (both from the very first commit `9becfff`, predating this session) contained REAL, live, unredacted secrets (`DB_PASS` x2, `SMTP_PASS`, `LDAP_PASS`, `IMAP_PASS`) — confirmed via safe length-only checks, sitting exposed in git history and already pushed to `gitlab.amf` this whole time. Root cause: two real tool bugs, both fixed and deployed to both hosts (`7e964988b6da56ff55b159c9397cf763`):
  1. **Same-indentation YAML block-sequence bug** (severe — silently zeroed extraction for an ENTIRE `environment:` block, not just one line): valid YAML allows a `- item` list entry to sit at the SAME indentation as its parent `environment:` key, not just deeper; the block-exit check treated "same indentation" as "block ended," so the very first list item looked like it was already outside the block. Found via a real sameersbn/gitlab-style compose file using this style throughout.
  2. **`_PASS` keyword gap**: `DB_PASS`/`SMTP_PASS`/`LDAP_PASS`/`IMAP_PASS` use the `_PASS` suffix convention, not `_PASSWORD`/`_PASSWD`/`_PWD`; the keyword list deliberately excluded bare `PASS` (to avoid a known false positive, a `PASS=0;FAIL=0` test-counter), but never added an anchored `_PASS` (with the literal underscore) variant. Fixed by requiring the underscore, so the original false-positive case still doesn't match.
  Remediation: rotated/being rotated credentials for DB/SMTP/LDAP (user's responsibility, in progress); git history rewritten via `git-filter-repo` (both file paths stripped from all 9 commits) in a disposable mirror clone, force-pushed to `gitlab.amf` after temporarily allowing force-push on the protected `main` branch (restored afterward), `/srv`'s live checkout synced via `git fetch` + `git reset --hard origin/main` (working tree was clean beforehand, confirmed safe). A live GitLab access token (`local-copy-on-host-db1`) was also accidentally exposed in chat via `git-filter-repo`'s own remote-removal notice during this process — flagged immediately, user to revoke and replace. Still pending: reprocess `gitlab`'s real files with the now-fixed tool and do a proper Step 8 conversion; also still has `registry-config.yml` (already clean) and `old_gitlab_container_settings.txt` (real file, needs fresh review with the fixed tool). **Update — fully resolved**: found and fixed a THIRD real tool bug during reprocessing — a plain (unquoted) YAML scalar in a LIST-style item (`- GITLAB_OMNIBUS_CONFIG=|`, where `|` is just a literal character, not a block-scalar indicator in that position) folds across following, more-deeply-indented lines; the list-item extraction path had zero multi-line detection at all (only the map-item path checked for explicit `|`/`>`), so it moved only a 1-character fragment to `${VAR}` and left the real multi-line continuation as orphaned, structurally invalid YAML — confirmed via `docker compose config` failing to parse the first attempt. Fixed by extending block-scalar-style detection (skip extraction, isolate for redaction, never touch structurally) to the list-item path too, triggered generically by "next line is more indented," not by any literal marker. Tested via synthetic repro (fake credentials) before deploying to both hosts (`1f3dfbcdcd490619827234bf7d06a168`). Reprocessed: 132 vars extracted, `GITLAB_OMNIBUS_CONFIG`'s actual content (just `external_url`/`monitoring_whitelist`/nginx proxy-header settings, manually confirmed non-secret) correctly left inline, `docker compose config` parses clean, dry-run confirmed identical to untouched original (pre-existing container-naming quirk, unrelated to our change). Committed & pushed.
- [x] gitlab-ee — real `docker-compose.yaml` converted to working `${VAR}`+`.env` config (`GITLAB_OMNIBUS_CONFIG` block scalar's 5 secrets extracted too), validated with `docker compose config` + `--dry-run` (no change vs. running container), stale `.sanitized` twin dropped; committed & pushed (`cfecbe5`)
- [x] gitlab-runner — compose file already clean (no conversion needed); `config.toml`/`config.toml.bak2` twins refreshed with current tool version (duplicate-secret fix), stays on old REDACTED pattern; committed & pushed (`cfecbe5`)
- [x] grafana-agent — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); committed & pushed (`1df14c0`)
- [x] grafana-loki — converted & validated, no change vs running containers; collision fix worked automatically (`VIRTUAL_HOST_2`/`VIRTUAL_POST_2` — note real key name is `VIRTUAL_POST`, not a typo we introduced); `grafana.ini`/`ldap.toml`/`loki-config.yaml` stay on old pattern; committed & pushed (`1df14c0`)
- [x] ldap — converted & validated, no change vs running containers (22 vars extracted); `logs.txt` (91MB, already root-`.gitignore`-excluded by exact path) deliberately not scanned — killed a slow `detect-secrets` run against it mid-scan since it doesn't need reviewing regardless of content; `certs/`/`ldap-passwd-webui/` (nested repo) already out of scope; committed & pushed (`1df14c0`)
- [x] minio — converted & validated; no pre-existing `REDACTED` corruption this time (unlike db2); collision fix worked automatically (`VIRTUAL_HOST_2`/`VIRTUAL_PORT_2`); "Recreated" on `minio-nginx` confirmed pre-existing; `ldap.env`/`nginx-console.conf` stay on old pattern; 3 stray backup/cluster compose files (`docker-compose.backup2`, `docker-compose.yml.backup`, `docker-compose.yml.cluster`) excluded outright as junk, no sanitized twins tracked; committed & pushed (`cfecbe5`); **patched after the aws-s3-upload sweep**: `MINIO_BROWSER_REDIRECT_URL`, `MINIO_CERTS_DIR`, `SSL_CERT_FILE` had been missed by the unindented-comment bug, now extracted to `${VAR}` (the latter two are `_CERT_*`-keyword false positives, same pattern as `patroni`, not real secrets); committed & pushed (`1df14c0`)
- [x] mongo — converted & validated, no change vs running containers (6 vars extracted); `app.json`/`config.json` stay on old pattern. **Real gap caught**: the tool reported `keyfile` (MongoDB's replica-set auth `--keyFile`, i.e. the actual cluster auth secret) as "0 redactions, track as-is" — gitleaks/trufflehog/entropy rules missed it since it's unstructured base64 key material with no recognizable pattern. Manually added to `.gitignore` anyway; same "nothing found ≠ confirmed clean" precedent as `pg-cluster-instance-2`'s `SPILO_CONFIGURATION`. Worth checking `mongo-production` for the same file. Committed & pushed (`1df14c0`)
- [x] mongo-production — converted & validated, no change vs running container (2 vars); `keyfile` correctly excluded (permission-denied, flagged automatically this time); committed & pushed (`1df14c0`)
- [x] netboot — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); committed & pushed (`1df14c0`)
- [x] clickhouse-external — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`, not something we broke); committed & pushed (`cfecbe5`)
- [x] clickhouse-staging — converted & validated; "Recreated" confirmed pre-existing; `config.xml`/`index.html`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (all refreshed, gitleaks-clean); committed & pushed (`cfecbe5`); **patched after the aws-s3-upload sweep**: `VIRTUAL_PORT` had been missed by the unindented-comment bug, now extracted to `${VAR}`; committed & pushed (`1df14c0`)
- [x] clickhouse-production — converted & validated; "Recreated" confirmed pre-existing; `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (all refreshed, gitleaks-clean); committed & pushed (`cfecbe5`); **patched after the gitlab re-sweep**: `VIRTUAL_PORT` had been missed by the same-indentation bug (config-only, not secret), now extracted, "Recreated" re-confirmed pre-existing; committed & pushed
- [x] clickhouse — db1-specific, no db2/marketdata equivalent exists on this host; converted & validated; "Recreated" confirmed pre-existing; `users.xml` stays on old pattern; committed & pushed (`cfecbe5`)
- [x] nginx-lb — converted & validated, both containers stayed "Running" (no recreate); `.gitignore` fixed to exclude only the `.pre-versioning-backup`; committed & pushed (`cfecbe5`)
- [x] patroni — converted & validated (33 vars); service not currently running (confirmed identical vs. `.pre-versioning-backup`); `ETCD_*_CERT_*`/`PATRONI_*_CERT*`/`_CAFILE`/`_CACERT` classifications confirmed false positives via length check (3-24 chars, booleans/paths, not embedded cert content) — same pattern as db2's `_archiv/patroni`; committed & pushed (`1df14c0`)
- [x] postgres — converted & validated, all 3 containers stayed "Running" (no drift, unlike db2's `postgres-develop`); committed & pushed (`cfecbe5`); **patched after the gitlab re-sweep**: `VIRTUAL_HOST`/`VIRTUAL_POST` had been missed by the same-indentation bug (config-only, not secrets), now extracted; committed & pushed
- [x] promtail — compose file already clean (no conversion needed); `promtail-config.yaml` stays on old pattern (gitleaks-clean); committed & pushed (`1df14c0`)
- [ ] proxy — deferred, more complex than usual: compose file itself is already clean (no conversion needed), but the directory also has a root-only `.key` (private key), two SQL/mongo dump files with 1 redaction each, 3 binary mongo dumps, and a stray untracked `CA.pem.bak.2026.08.25` not yet in `.gitignore` — needs a deliberate decision on whether dump files should be tracked (redacted) at all vs. excluded outright
- [x] redis — compose file already clean (no conversion needed); `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to read, now has a proper reviewed twin); committed & pushed (`cfecbe5`)
- [x] redis-production — converted & validated, no change vs running containers; `redis.conf`/`sentinel.conf` stay on old pattern; committed & pushed (`cfecbe5`)
- [x] redis-sentinel — compose file already clean (no conversion needed); `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to read, now has a proper reviewed twin); committed & pushed (`cfecbe5`)
- [x] redis-staging — converted & validated, no change vs running containers; `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to even read, now has a proper reviewed `.sanitized` twin); committed & pushed (`cfecbe5`)
- [x] registry — converted & validated (7 vars); service not currently running (confirmed identical vs. `.pre-versioning-backup`); `docker-proxy-config.yml` already clean; committed & pushed (`1df14c0`)
- [x] restic — converted & validated (both `docker-compose.yaml` + `docker-compose.override.yaml` needed for validation); `POST_COMMANDS_SUCCESS` block deferred, same as db2; committed & pushed (`cfecbe5`)
- [x] restic-restore — converted & validated; service is NOT normally running (on-demand restore tool) — dry-run shows "Created"/"Started" rather than "Running", confirmed identical against untouched `.pre-versioning-backup` so this is just its normal dormant state, not disruption; stray `docker-compose.yaml.back` treated as junk, excluded outright (no sanitized twin tracked); committed & pushed (`cfecbe5`)
- [x] rustfs — converted & validated; "Recreated" confirmed pre-existing (image drift, matches db2 precedent); `nginx-console.conf` stays on old pattern; stray `.docker-compose.yaml.swp` (vim swap file) excluded; committed & pushed (`cfecbe5`)
- [x] samba-backup — converted (2 vars: USERNAME/PASSWORD); no container currently exists (`docker ps -a` empty) and the raw file is legacy Compose v1 format (`version: '1'`, no `services:` wrapper) — modern `docker compose` v2 rejects it with `additional properties 'samba' not allowed`, confirmed identical against the untouched original, so pre-existing and out of scope to fix here; `${VAR}` substitution confirmed correct via the legacy `docker-compose` v1 tool. Stray `docker-compose.yml2` excluded outright as junk. Test/fake credentials only (`joe`/`samba`), user confirmed no rotation needed after an accidental raw-stdout exposure mid-troubleshooting (process lesson: always redirect `config` stdout to a file); committed & pushed (`1df14c0`)
- [x] samba-ldap — out of scope, own nested `.git` repo (excluded wholesale in root `.gitignore`), not a candidate for this workflow
- [x] shhh — out of scope, own nested `.git` repo (excluded wholesale in root `.gitignore`), not a candidate for this workflow
- [x] uptime-kuma — converted & validated, no change vs running container; `Uptime-Kuma-Report/` subdirectory already excluded as its own nested repo; committed & pushed (`1df14c0`)
- [x] watchtower — converted & validated, no change vs. running container; existing `.env` appended (not overwritten); committed & pushed (`cfecbe5`)
- [x] xpressfeed — converted & validated, no change vs running container (7 vars); `Desktop/`/`backup/` already excluded as large data dirs; committed & pushed (`1df14c0`)
- [x] yopass — converted & validated; "Recreated" on `yopass` confirmed pre-existing; committed & pushed (`1df14c0`)

Out of scope:
- `sentry` — excluded from git entirely (data volume + your call)
- `dockprom`, `netbox-docker`, `elastdocker` — own nested .git repos
- `gitlab-ee-failed`, `grafana-loki-old`, `sentry-old`, `sentrytest`, `infisical_test`, `http-test` — stale/dead duplicates
- `vault`, `vault2`, `infisical`, `pg-cluster-instance-1`, `healthchecks`, `nessie` — live/sensitive services, handled by hand

## cpu1/cpu2 — new hosts, first-time rollout (never under git before)

Much messier/more sensitive than db1/db2: `proxy/CA.key` is the actual CA private key
signing every cert on these hosts; `cpu1` also has `vault-agent-example/vault-token` and
`conda/vault-token` (live tokens despite the "example" name); `conda/` on both hosts is a
cluttered dev sandbox (8+ `.env` variants, many stray `.bak`/`.old`/date-suffixed backup
compose/Dockerfile copies) — deliberately skipped in `run_all.sh`'s `SKIP` array, needs a
by-hand pass later, not blind bulk processing. `cpu1` also has an 18GB world-writable
`amfileon-conda.tar` loose at `/srv/docker` root, duplicated in `conda/` — excluded via
`.gitignore`, flagged to the host owner separately (permissions + duplication are a
pre-existing issue unrelated to git). Both hosts have `dockprom/` as a nested `.git` repo
(same as db1/db2) and `proxy/htpasswd` as a *directory* (one file per environment), not a
single file like db1/db2 — `gitignore-cpu1`/`gitignore-cpu2` both account for this.

Prerequisites: apt's `gitleaks`/`pipx` packages and `python3.10-venv` all 404'd from a
stale/broken mirror on both hosts — installed via the documented fallbacks instead
(gitleaks: manual GitHub release download; detect-secrets: PyPI's `get-pip.py` bootstrap
+ `pip install --user`, skipping `pipx` entirely; both confirmed working, shared via a
`/usr/local/bin/detect-secrets` symlink to `ssa`'s copy, same pattern as db1/db2).

User's explicit guidance for these hosts: prefer excluding anything ambiguous in
`.gitignore` over spending time confirming it's safe — the goal is a zero-risk commit,
not maximal coverage.

### cpu1 — live services

**First commit done and pushed** (`573a933`, `main`, 96 files, repo root `/srv`). All 10
services below converted/reviewed and included. Caught two real gaps before committing —
`clickhouse` and `restic-restore` each had their per-service `.gitignore` never actually
created (likely lost mid-session), which let their `docker-compose.yaml.pre-versioning-backup`
(the true original, holding real secrets) get staged by `git add -A`; `git check-ignore -v`
per-service is what caught it, fixed via `git rm -r --cached . -f -q` + re-`add -A` (README
Gotcha #2 — a `.gitignore` rule never retroactively un-stages a file already in the index).
**Second commit done and pushed** (`5c8b13f`, `main`): `.env.example` built and committed
for `clickhouse`/`clickhouse-dev`/`minio`/`restic`/`restic-restore`/`watchtower` (the 6
services with a real `.env`), deliberately kept separate from the first commit per request.
All pre-commit checks (gitleaks/trufflehog/detect-secrets/key-name) clean, no findings.
cpu1 rollout now fully complete.

- [x] clickhouse — converted & validated (3 vars); "Recreated" confirmed pre-existing; `config.xml`/`keeper.xml`/`users.xml` already clean; `docker-compose.yaml.save` (stray junk duplicate, permission-denied as ssa) already covered by the generic `*.save` pattern; **`.gitignore` was initially missing entirely** (caught before commit, see note above), fixed
- [x] clickhouse-dev — converted & validated (7 vars); `VIRTUAL_HOST_2`/`VIRTUAL_PORT_2` disambiguation worked automatically; "Recreated" confirmed pre-existing; `chproxy.yml`/`config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (all gitleaks-clean); `SSL_CERT_FILE` classified secret, same `_CERT_FILE`-keyword false positive as elsewhere
- [x] filebeat — already clean (0 vars, 0 redactions, matches db1/db2's filebeat exactly); nothing to convert, exclude, or dry-run test; tracked as-is
- [x] gitlab-runner — compose file already clean (no conversion needed); `config.toml` stays on old pattern (gitleaks-clean); `config.toml.template.gitlab.amf` already clean
- [x] minio — converted & validated (12 vars); no pre-existing `REDACTED` corruption; collision fix worked automatically (`VIRTUAL_HOST_2`/`VIRTUAL_PORT_2`); "Recreated" confirmed pre-existing; `ldap.env` stays on old pattern (gitleaks-clean); `docker-compose.yml.backup` (stray junk, same pattern as db1/db2) already covered by generic `*.backup` rule, no twin tracked
- [x] mongo — no compose file in this directory at all (just a bare `keyfile`, matching the earlier directory listing); nothing to convert or dry-run test; `keyfile` excluded via `.gitignore` (unstructured key material, same caution as db1's mongo)
- [x] promtail — compose file already clean (no conversion needed); `promtail-config.yaml` stays on old pattern (gitleaks-clean)
- [x] proxy — compose file already clean (0 vars, no conversion needed); `nginx.tmpl` stays on old pattern (gitleaks-clean); `develop.tar.gz.base64` excluded outright via the generic root `*.tar.gz.base64` rule, no twin tracked; `CA.key` and all other `.crt`/`.csr`/`.pem`/`.key`/`.ext` certs correctly never scanned (tool skips cert/key files by extension); `htpasswd/` directory correctly never recursed into (excluded wholesale via `.gitignore`); `CA.pem.BAK`/`watchtower-post-check-hc-ping.sh` already clean
- [x] restic — converted & validated (10 vars, both `docker-compose.yaml` + `docker-compose.override.yaml` needed for validation); no change vs running container; `POST_COMMANDS_SUCCESS` block deferred, same healthchecks-ping-UUID pattern already accepted on db1/db2
- [x] restic-restore — converted & validated (7 vars); service not currently running (confirmed identical vs. `.pre-versioning-backup`, same on-demand-tool pattern as db1/db2); **`.gitignore` was initially missing entirely** (caught before commit, see note above), fixed
- [x] watchtower — converted & validated; "Recreated" confirmed pre-existing (image drift, same as every other host); existing `.env` appended, no key overlap

Out of scope / deferred: `vault-agent-example` (live vault-token despite the name),
`conda` (messy dev sandbox, excluded wholesale in `.gitignore`), `dockprom` (own nested .git).

### cpu2 — live services

**Repo set up and first commit done** (`c50a55c`, pushed to `infrastructure/cpu2.git`,
branch `main`, token `local-copy-on-host-cpu2`). Two real gaps caught before committing,
both fixed:
1. `conda/` was only ever a *comment* in `gitignore-cpu2`, not an actual exclusion
   pattern — being in `run_all.sh`'s `SKIP` array only stops the sanitizer from
   scanning it, it does **not** stop `git add -A` from staging its raw contents. The
   pre-commit hook's key-name check caught real secret-shaped assignments in
   `conda/docker-compose.yaml` and `conda/entrypoint.sh` on the very first `git add -A`.
   Fixed by adding an actual `conda/` wholesale-exclusion line to both `gitignore-cpu1`
   and `gitignore-cpu2` (cpu1 has the identical gap, flagged to the other session).
2. `watchtower`'s `.gitignore` (excluding `docker-compose.yaml.pre-versioning-backup`,
   the true original with real secret values) was never actually created — missed
   before moving to the next service. Caught via careful `git status` review before
   the first commit, not by any scanner (the real values in that particular file
   apparently didn't trip gitleaks/trufflehog/key-name checks — a reminder that
   `git status` review before every commit matters regardless of scanner results).

- [x] watchtower — converted & validated; "Recreated" confirmed pre-existing (image drift, same pattern as every other host); existing `.env` appended, no key overlap; `.gitignore` gap caught and fixed before commit (see above); committed & pushed (`c50a55c`)
- [x] clickhouse-dev — converted & validated (7 vars, collision fix worked automatically for `VIRTUAL_HOST_2`/`VIRTUAL_PORT_2`); `SSL_CERT_FILE` confirmed false positive (19 chars, a path); "Recreated" on keeper/ch confirmed pre-existing; `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (gitleaks-clean), `chproxy.yml` already clean; committed & pushed (`c50a55c`)
- [x] promtail — compose file already clean (no conversion needed); `promtail-config.yaml` stays on old pattern (gitleaks-clean); committed & pushed (`c50a55c`)
- [x] proxy — converted & validated (2 vars); "Recreated" on all 3 containers confirmed pre-existing; `nginx.tmpl` stays on old pattern (gitleaks-clean); `CA.pem.BAK`/`CA.pem` correctly excluded (the latter via the generic `*.pem` pattern); committed & pushed (`c50a55c`)
- [x] restic — converted & validated (10 vars, both compose files needed for validation), no change vs running container; `POST_COMMANDS_SUCCESS` block scalar deferred, gitleaks-clean; `docker-compose.override.yaml`/`excludes.txt` already clean, tracked as-is; committed & pushed (`c50a55c`)
- [x] restic-restore — converted & validated (7 vars); service not currently running (on-demand tool, confirmed identical vs. `.pre-versioning-backup`); committed & pushed (`c50a55c`)

`.env.example` built for all 5 services with a real `.env` (`watchtower`, `clickhouse-dev`,
`proxy`, `restic`, `restic-restore` — `promtail` had 0 vars, no `.env` exists for it).
Committed & pushed (`67fbcd0`). One gitleaks false positive hit along the way:
`clickhouse-dev/.env.example` line 3 (`CH_PASSWORD=`, genuinely 0 chars — confirmed via
safe length check before bypassing with `--no-verify`, same "check first" rule the
pre-commit hook itself prints) — gitleaks likely misattributed it from an adjacent
real-value line (`CHVER`/`KEEPER_HOSTNAME`), same general class of scanner
misattribution already documented for block scalars in the README.

Out of scope / deferred: `conda` (messy dev sandbox, same as cpu1, needs deliberate
by-hand pass — also has a new date-suffixed backup-file naming convention not seen on
other hosts, pattern added to `gitignore-cpu2`; now properly wholesale-excluded, not
just commented), `dockprom` (own nested .git).

## gpu1 — new host, first-time rollout (IN PROGRESS, not yet committed)

**Not a from-scratch host like cpu1/cpu2** — someone else had already `git init`'d
`/srv/docker` itself (repo root at `/srv/docker`, not `/srv`) with their own ad-hoc
`.gitignore` and 15 commits of real history, no remote configured (never pushed
anywhere), and **no `.githooks`/pre-commit hook on any of those commits** — meaning
none of that history was ever scanned by anything. Decision (user's call): back up
that `.git` rather than try to audit/reconcile it, and redo the whole host fresh with
this project's actual tooling, matching the `/srv`-rooted convention used on
db1/db2/cpu1/cpu2.

- Old `.git` moved (not deleted) to `/home/ssa/gpu1-git-backup/docker-git-20261005/`
  — never scanned for historical secret exposure (deliberately deferred; since it
  never had a remote, whatever's in it never left this host). Revisit only if it
  ever actually matters.
- Fresh `git init` at `/srv` (not `/srv/docker`), `gitignore-gpu1` built from the
  cpu1 template — same `/*` + `!/docker/` scope-limiting pattern, plus a new
  `archived/` wholesale exclusion (a holding pen of retired services — `postgres`,
  `trading`/`trading-production`/`trading-test`, `gitlab-runner` subdirs, a loose
  `mongo_staging.tar.gz` — not structured as a normal single-compose-file service
  directory, not live, not worth scanning). `archived` also added to `run_all.sh`'s
  `SKIP` array (shared across all hosts, no-op where it doesn't exist).
- Tooling installed fresh (no prior gitleaks/trufflehog/detect-secrets on this host):
  gitleaks 8.30.1 and trufflehog 3.98.0 via their standard GitHub-release/install-script
  methods, detect-secrets 1.5.0 via the `get-pip.py` bootstrap for `ssa`. **New gotcha
  found and documented** (README): a `/usr/local/bin/detect-secrets` symlink to `ssa`'s
  `--user` install does NOT work for root — Python resolves user-site-packages by the
  *executing* user's home, not the file owner's, so root hit
  `ModuleNotFoundError: No module named 'detect_secrets'` (discovered when the sanitizer
  was accidentally run as root once). Fixed by giving root its own real
  `get-pip.py --user` install, re-symlinked. This matters beyond just the sanitizer:
  the eventual `git commit`'s pre-commit hook will also run as root (root-owned `/srv`),
  so this would have silently broken that safety net too if left unfixed.
- **New real tool bug found and fixed** in `sanitize_service_files.py` (see README
  Gotcha #5): nginx's `server_tokens off;` directive contains "token" as a substring,
  false-triggering the keyword regex; the captured value `off;` then got treated as a
  "confirmed secret" and the cross-file propagation logic redacted every other `off;`
  occurrence in `proxy/nginx.tmpl` — `auth_basic`, `auth_request`, `ssl_session_tickets`,
  `proxy_buffering`, `access_log`, `default`, `ssl_prefer_server_ciphers`, all turned into
  invalid nginx syntax that would have broken the live proxy on deploy. None of
  gitleaks/trufflehog/detect-secrets flagged anything here — purely the tool's own
  keyword fallback. Fixed by never treating a bare `on`/`off`/`true`/`false`/`yes`/`no`
  toggle as a secret value. Verified via synthetic repro (both the false-positive fix
  AND that a real `TOKEN`-named secret still gets caught). **Fixed locally but NOT yet
  redeployed to gpu1** (or any other host) — do that before re-running `proxy`.

### gpu1 — live services (status as of pausing this session)

- [x] watchtower — converted & validated; stale `WATCHTOWER_SCHEDULE` in the pre-existing
  `.env.example` (said `FRI-SAT`, live value is `SAT`) manually corrected; "Recreated"
  confirmed pre-existing via `docker ps`; `.env2`/`docker-compose.yml.backup` excluded
  (`docker-compose.yml.backup` already covered by the generic `*.backup` pattern)
- [x] restic — converted & validated (6 vars); `POST_COMMANDS_SUCCESS` block scalar
  manually confirmed clean (just `curl ... ${HC_BACKUP_URL}`, already using substitution);
  `docker-compose.yaml.backup` already covered by generic `*.backup`, no twin needed
- [x] restic-restore — converted & validated (2 vars); `TZ` conflict (compose hardcoded
  `Europe/Berlin`, already matched `.env`'s existing value) manually converted to `${TZ}`;
  service not currently running (on-demand tool, confirmed via empty `docker ps -a`)
- [x] clickhouse — converted & validated (9 vars, all non-secret config, clean diff); real
  server (`gpu1.ch.amf`) and zookeeper (`gpu1.keeper.amf`) both confirmed `Up 6 weeks`
  unaffected. **Operational finding, unrelated to our work**: the `ch-ui` sub-service
  (`ghcr.io/caioricciuti/ch-ui:latest`) has been crash-looping for 5+ months —
  `RestartCount: 62838`, container created `2026-04-25`, image reference unchanged in
  the pre-versioning backup — confirmed pre-existing, not caused by this conversion.
  Flag for the colleague follow-up list (same category as db1/db2's not-running/outdated
  findings).
- [x] promtail — already clean (0 vars, 0 redactions in `docker-compose.yaml`/
  `promtail-config.yaml`); only flagged file (`promtail-config.yaml.backup`) already
  covered by the generic `*.backup` pattern — zero action needed, tracked as-is
- [x] filebeat — already clean (0 vars, 0 redactions anywhere) — zero action needed,
  tracked as-is
- [x] minio — converted & validated, but only after a **serious near-miss, fully
  resolved** (see README Gotcha #6). What looked like a `MINIO_ROOT_PASSWORD` CONFLICT
  (compose value 20 chars vs. `.env`'s 18 chars) was actually a real tool bug: the
  compose file already used bare `$MINIO_ROOT_PASSWORD` (no braces) — valid Compose
  syntax the tool didn't recognize as already-externalized, misreading it as a
  20-character hardcoded literal. The "mismatch" was fixed by manually copying that
  literal text into `.env`, which replaced the real password with the nonsense
  self-reference `MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD` — caught only because
  `docker compose config` then warned the variable was "not set, defaulting to blank."
  No file on disk still held the real value at that point; recovered directly from the
  live `minio-s3-1` container's own baked-in environment (`docker inspect` — the
  container had been running untouched the whole time), which also revealed the
  ORIGINAL `.env` value (18 chars) had itself been stale all along (the real live
  value is 16 chars). Root-caused and fixed in `sanitize_service_files.py`
  (`extract_compose_environment` now calls the existing `_is_placeholder` helper,
  which already recognized bare `$VAR`, instead of a narrower `${`-only check that
  never did) — verified via synthetic repro, deployed to gpu1
  (`b9dfa7022856add99f23acd32599f509`). Also hit the `server_tokens`/toggle-value
  false-positive bug (see below) on `nginx-console.conf`'s `server_tokens`/
  `ignore_invalid_headers`/`proxy_buffering`/`proxy_request_buffering`/
  `chunked_transfer_encoding`/`proxy_pass` lines — same fix, re-ran clean afterward.
  `ldap.env`'s 1 redaction confirmed correct (genuinely shows `REDACTED`, not a miss).
  Final state: 9 vars converted, `MINIO_ROOT_PASSWORD` manually converted to
  `${MINIO_ROOT_PASSWORD}` alongside them, `.env`/`.env.example` updated, both
  containers (`minio-nginx`, `minio-s3-1`) confirmed `Up 6 weeks` unaffected, no
  config warnings.
- [x] clickhouse-dev — converted & validated (7 vars; `SSL_CERT_FILE` classified secret
  confirmed to just be a path, `/etc/chproxy/ca.crt`, same `_CERT_FILE`-keyword false
  positive as other hosts). `config.xml`(1)/`keeper.xml`(2)/`ssl.xml`(2)/`users.xml`(3)
  redactions confirmed structurally valid XML (`xml.dom.minidom` parse succeeded on all
  4 — the earlier masked-diff "extra `MASKED<` prefix" oddity was just an imprecise sed
  masking artifact on the reviewing side, not real corruption) before swapping in.
  `docker compose config` clean, no warnings. **Operational finding, unrelated to our
  work**: both `gpu1.dev.ch.amf` and `gpu1.dev.keeper.amf` report `(unhealthy)` —
  confirmed pre-existing via `docker inspect` (`FailingStreak: 64063`, started
  `2026-08-22`, over 6 weeks of continuous health-check failures predating any of
  today's changes). Flag for the colleague follow-up list alongside `ch-ui`.
- [x] proxy — needed **zero action**: every file (`docker-compose.yml`,
  `docker-compose.yml.backup`, `nginx.tmpl`, `watchtower-post-check-hc-ping.sh`) came
  back completely clean once re-run with the fixed script (the original "12 redactions"
  on `nginx.tmpl` were entirely the `server_tokens`/toggle-value + `proxy_pass`
  false-positive bugs, both now fixed — `b9dfa7022856add99f23acd32599f509`). Nothing to
  swap, nothing to gitignore, tracked as-is.

**gpu1's live service list is now fully converted — all 9 services done** (`watchtower`,
`restic`, `restic-restore`, `clickhouse`, `promtail`, `filebeat`, `minio`,
`clickhouse-dev`, `proxy`). Next: `git add`/review/commit (no commit made yet on this
host — see the top-of-section note).

**Colleague follow-up list so far for gpu1** (operational issues found incidentally,
unrelated to the git work, same category as the db1/db2 list already sent): `ch-ui`
(minio... no, `clickhouse`'s UI sub-service) crash-looping 5+ months
(`ghcr.io/caioricciuti/ch-ui:latest`, image likely no longer exists upstream);
`clickhouse-dev`'s `gpu1.dev.ch.amf` + `gpu1.dev.keeper.amf` both failing health checks
for 6+ weeks continuously (still "Up", but worth investigating why the health check
itself fails).

Not yet started: nothing else outstanding in the live service list (`conda`, `dockprom`,
`archived` are the only remaining directories, all deliberately out of scope). **No
commit has been made yet on gpu1** — don't commit until minio/clickhouse-dev/proxy are
each individually resolved and validated, same bar as every other host.
