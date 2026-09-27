# Compose Sanitization Checklist

Goal for "done": the real `docker-compose.yaml` itself (not a separate `.sanitized`
twin) has every secret field replaced with a `${VAR}` reference, the true original is
preserved as `docker-compose.yaml.pre-versioning-backup`, a `.env` holds the real
values, and `docker compose config` validates clean with no unresolved-variable
warnings.

**PENDING**: run the unindented-comment sweep (same command used on db1 after the
`aws-s3-upload` bug) against db2's already-converted services too — db2 was converted
first, on the older buggy tool version, so it likely has the same class of missed
`${VAR}` extractions sitting in already-committed files:
```
find /srv/docker -name "*.pre-versioning-backup" -print0 | xargs -0 grep -n '^#[[:space:]]\+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:' 2>/dev/null | perl -pe 's/(:)[^:]*$/$1 <value hidden>/'
```

## db2 — live services

- [x] clickhouse-external — converted & validated; "Recreated" confirmed pre-existing (predates our change)
- [x] clickhouse-marketdata-production — converted & validated; "Recreated" confirmed pre-existing (predates our change); `chproxy.yml`/`config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern
- [x] clickhouse-marketdata-staging — converted & validated; `VIRTUAL_HOST_2`/`VIRTUAL_PORT_2` disambiguation (from the minio fix) worked automatically; "Recreated" confirmed pre-existing; `chproxy.yml`/`config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern
- [x] clickhouse-production — converted & validated; "Recreated" confirmed pre-existing (predates our change); `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern
- [x] clickhouse-staging — converted & validated; "Recreated" confirmed pre-existing (predates our change); `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on the old pattern
- [x] gitlab-runner — `docker-compose.yaml` converted & validated (`docker compose up -d --dry-run` confirmed no change vs. running container); `config.toml`/`uv.toml` stay on the old pattern
- [x] minio — converted & validated after finding & fixing two real tool bugs plus one pre-existing production issue (see below); `ldap.env`/`nginx-console.conf` stay on the old pattern
- [x] nginx-lb — converted & validated, no change vs. running containers
- [x] postgres — converted & validated; `postgres-develop`'s "Recreated" confirmed pre-existing (predates our change)
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

Note: `.env.example` built for all 14 services with a real `.env` (gitlab-ee, nginx-lb,
authentik, watchtower, restic, restic-restore, rustfs, minio, redis-staging, postgres,
clickhouse-external, clickhouse-staging, clickhouse-production, clickhouse,
redis-production) — committed & pushed. Also fixed the same `.env.*` / `.env.example`
gitignore gap here that was found on db2 (deferred earlier in this session, now closed).

- [x] authentik — `docker-compose.yaml` converted to working `${VAR}`+`.env`; `docker-compose.override.yml` stays real/untouched (loaded live by Compose) with its `.sanitized` REDACTED twin tracked instead; "Recreated" on 3 containers confirmed pre-existing (matches untouched `.pre-versioning-backup`); committed & pushed (`cfecbe5`)
- [x] aws-s3-upload — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); `credentials` stays on old pattern. **Found & fixed a real tool bug**: an unindented commented-out duplicate line inside `environment:` (e.g. `#      S3_BUCKET: ...` flush at column 0) was misread as ending the block, silently stopping `${VAR}` extraction for every real line after it — `S3_BUCKET`/`DESTINATION_PATH` were left with real literal values untouched in the `.sanitized` twin, and `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` only got a REDACTED fallback (would have broken real S3 auth if swapped in as-is). Fixed in `sanitize_service_files.py` (comment lines now get the same block-boundary exemption blank lines already had), deployed to both hosts (`1d9a3403da8d35ff818eb858c70af0e5`); not yet staged
- [x] devpi — converted & validated; "Recreated" on `devpi-nginx` confirmed pre-existing; `nginx.conf` stays on old pattern; not yet staged
- [x] docker-rclone-sync — out of scope, own nested `.git` repo (excluded wholesale in root `.gitignore`), not a candidate for this workflow
- [x] filebeat — nothing to do, already clean and already tracked as-is (0 redactions in both `docker-compose.yml` and `filebeat.yml`)
- [x] flame — converted & validated; "Recreated" confirmed pre-existing (unrelated `version:` obsolete-attribute warning, harmless); not yet staged
- [ ] gitlab — deferred: compose file has 17 "generic redaction pass" hits outside the environment block plus 9 extracted vars (`REGISTRY_AUTH_TOKEN_*` classified secret, likely `_CERT_*`/`_TOKEN_`-keyword false positives, not yet confirmed either way); `.sanitized` output shows `LDAP_PASS=`/`SMTP_PASS=`/`DB_PASS=` with nothing after the `=` — gitleaks reports 0 leaks on the `.sanitized` file, so no actual secret is exposed, but it's unconfirmed whether these were genuinely empty/unset in the real original or whether the tool silently dropped real content instead of redacting it. Needs the safe length-only check (never paste the actual value) before trusting this service's conversion. Also has `old_gitlab_container_settings.txt` (31 redactions, stays on old pattern) and a clean `registry-config.yml`. Do NOT swap anything in for this service until resolved.
- [x] gitlab-ee — real `docker-compose.yaml` converted to working `${VAR}`+`.env` config (`GITLAB_OMNIBUS_CONFIG` block scalar's 5 secrets extracted too), validated with `docker compose config` + `--dry-run` (no change vs. running container), stale `.sanitized` twin dropped; committed & pushed (`cfecbe5`)
- [x] gitlab-runner — compose file already clean (no conversion needed); `config.toml`/`config.toml.bak2` twins refreshed with current tool version (duplicate-secret fix), stays on old REDACTED pattern; committed & pushed (`cfecbe5`)
- [x] grafana-agent — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); not yet staged
- [x] grafana-loki — converted & validated, no change vs running containers; collision fix worked automatically (`VIRTUAL_HOST_2`/`VIRTUAL_POST_2` — note real key name is `VIRTUAL_POST`, not a typo we introduced); `grafana.ini`/`ldap.toml`/`loki-config.yaml` stay on old pattern; not yet staged
- [x] ldap — converted & validated, no change vs running containers (22 vars extracted); `logs.txt` (91MB, already root-`.gitignore`-excluded by exact path) deliberately not scanned — killed a slow `detect-secrets` run against it mid-scan since it doesn't need reviewing regardless of content; `certs/`/`ldap-passwd-webui/` (nested repo) already out of scope; not yet staged
- [x] minio — converted & validated; no pre-existing `REDACTED` corruption this time (unlike db2); collision fix worked automatically (`VIRTUAL_HOST_2`/`VIRTUAL_PORT_2`); "Recreated" on `minio-nginx` confirmed pre-existing; `ldap.env`/`nginx-console.conf` stay on old pattern; 3 stray backup/cluster compose files (`docker-compose.backup2`, `docker-compose.yml.backup`, `docker-compose.yml.cluster`) excluded outright as junk, no sanitized twins tracked; committed & pushed (`cfecbe5`); **patched after the aws-s3-upload sweep**: `MINIO_BROWSER_REDIRECT_URL`, `MINIO_CERTS_DIR`, `SSL_CERT_FILE` had been missed by the unindented-comment bug, now extracted to `${VAR}` (the latter two are `_CERT_*`-keyword false positives, same pattern as `patroni`, not real secrets); not yet staged
- [x] mongo — converted & validated, no change vs running containers (6 vars extracted); `app.json`/`config.json` stay on old pattern. **Real gap caught**: the tool reported `keyfile` (MongoDB's replica-set auth `--keyFile`, i.e. the actual cluster auth secret) as "0 redactions, track as-is" — gitleaks/trufflehog/entropy rules missed it since it's unstructured base64 key material with no recognizable pattern. Manually added to `.gitignore` anyway; same "nothing found ≠ confirmed clean" precedent as `pg-cluster-instance-2`'s `SPILO_CONFIGURATION`. Worth checking `mongo-production` for the same file. Not yet staged
- [x] mongo-production — converted & validated, no change vs running container (2 vars); `keyfile` correctly excluded (permission-denied, flagged automatically this time); not yet staged
- [x] netboot — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`); not yet staged
- [x] clickhouse-external — converted & validated; service not currently running (confirmed identical vs. `.pre-versioning-backup`, not something we broke); committed & pushed (`cfecbe5`)
- [x] clickhouse-staging — converted & validated; "Recreated" confirmed pre-existing; `config.xml`/`index.html`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (all refreshed, gitleaks-clean); committed & pushed (`cfecbe5`); **patched after the aws-s3-upload sweep**: `VIRTUAL_PORT` had been missed by the unindented-comment bug, now extracted to `${VAR}`; not yet staged
- [x] clickhouse-production — converted & validated; "Recreated" confirmed pre-existing; `config.xml`/`keeper.xml`/`ssl.xml`/`users.xml` stay on old pattern (all refreshed, gitleaks-clean); committed & pushed (`cfecbe5`)
- [x] clickhouse — db1-specific, no db2/marketdata equivalent exists on this host; converted & validated; "Recreated" confirmed pre-existing; `users.xml` stays on old pattern; committed & pushed (`cfecbe5`)
- [x] nginx-lb — converted & validated, both containers stayed "Running" (no recreate); `.gitignore` fixed to exclude only the `.pre-versioning-backup`; committed & pushed (`cfecbe5`)
- [x] patroni — converted & validated (33 vars); service not currently running (confirmed identical vs. `.pre-versioning-backup`); `ETCD_*_CERT_*`/`PATRONI_*_CERT*`/`_CAFILE`/`_CACERT` classifications confirmed false positives via length check (3-24 chars, booleans/paths, not embedded cert content) — same pattern as db2's `_archiv/patroni`; not yet staged
- [x] postgres — converted & validated, all 3 containers stayed "Running" (no drift, unlike db2's `postgres-develop`); committed & pushed (`cfecbe5`)
- [x] promtail — compose file already clean (no conversion needed); `promtail-config.yaml` stays on old pattern (gitleaks-clean); not yet staged
- [ ] proxy — deferred, more complex than usual: compose file itself is already clean (no conversion needed), but the directory also has a root-only `.key` (private key), two SQL/mongo dump files with 1 redaction each, 3 binary mongo dumps, and a stray untracked `CA.pem.bak.2026.08.25` not yet in `.gitignore` — needs a deliberate decision on whether dump files should be tracked (redacted) at all vs. excluded outright
- [x] redis — compose file already clean (no conversion needed); `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to read, now has a proper reviewed twin); committed & pushed (`cfecbe5`)
- [x] redis-production — converted & validated, no change vs running containers; `redis.conf`/`sentinel.conf` stay on old pattern; committed & pushed (`cfecbe5`)
- [x] redis-sentinel — compose file already clean (no conversion needed); `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to read, now has a proper reviewed twin); committed & pushed (`cfecbe5`)
- [x] redis-staging — converted & validated, no change vs running containers; `redis.conf`/`sentinel.conf` stay on old pattern (`sentinel.conf` needed root to even read, now has a proper reviewed `.sanitized` twin); committed & pushed (`cfecbe5`)
- [x] registry — converted & validated (7 vars); service not currently running (confirmed identical vs. `.pre-versioning-backup`); `docker-proxy-config.yml` already clean; not yet staged
- [x] restic — converted & validated (both `docker-compose.yaml` + `docker-compose.override.yaml` needed for validation); `POST_COMMANDS_SUCCESS` block deferred, same as db2; committed & pushed (`cfecbe5`)
- [x] restic-restore — converted & validated; service is NOT normally running (on-demand restore tool) — dry-run shows "Created"/"Started" rather than "Running", confirmed identical against untouched `.pre-versioning-backup` so this is just its normal dormant state, not disruption; stray `docker-compose.yaml.back` treated as junk, excluded outright (no sanitized twin tracked); committed & pushed (`cfecbe5`)
- [x] rustfs — converted & validated; "Recreated" confirmed pre-existing (image drift, matches db2 precedent); `nginx-console.conf` stays on old pattern; stray `.docker-compose.yaml.swp` (vim swap file) excluded; committed & pushed (`cfecbe5`)
- [x] samba-backup — converted (2 vars: USERNAME/PASSWORD); no container currently exists (`docker ps -a` empty) and the raw file is legacy Compose v1 format (`version: '1'`, no `services:` wrapper) — modern `docker compose` v2 rejects it with `additional properties 'samba' not allowed`, confirmed identical against the untouched original, so pre-existing and out of scope to fix here; `${VAR}` substitution confirmed correct via the legacy `docker-compose` v1 tool. Stray `docker-compose.yml2` excluded outright as junk. Test/fake credentials only (`joe`/`samba`), user confirmed no rotation needed after an accidental raw-stdout exposure mid-troubleshooting (process lesson: always redirect `config` stdout to a file); not yet staged
- [x] samba-ldap — out of scope, own nested `.git` repo (excluded wholesale in root `.gitignore`), not a candidate for this workflow
- [ ] shhh
- [ ] uptime-kuma
- [x] watchtower — converted & validated, no change vs. running container; existing `.env` appended (not overwritten); committed & pushed (`cfecbe5`)
- [ ] xpressfeed
- [ ] yopass

Out of scope:
- `sentry` — excluded from git entirely (data volume + your call)
- `dockprom`, `netbox-docker`, `elastdocker` — own nested .git repos
- `gitlab-ee-failed`, `grafana-loki-old`, `sentry-old`, `sentrytest`, `infisical_test`, `http-test` — stale/dead duplicates
- `vault`, `vault2`, `infisical`, `pg-cluster-instance-1`, `healthchecks`, `nessie` — live/sensitive services, handled by hand
