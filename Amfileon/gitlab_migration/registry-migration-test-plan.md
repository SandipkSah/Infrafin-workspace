# Registry Migration — Test Plan (Approach A vs B)

**Objective:** On db2, measure and validate both migration approaches on a **throwaway, isolated** GitLab —
without touching `gitlab-ce2`, the shared proxy, or `preview.dagster.amf`.

**What this proves:** the *procedure* works end-to-end, and the *per-tag import speed* — which you then
extrapolate to the real registry's tag count. (It does **not** reproduce 1.8 TB; timing scales with
**tag/manifest count**, so we measure that and multiply.)

**Design:** seed a synthetic **legacy** registry → snapshot it as a baseline → run **Approach B** (one-step)
from the baseline → **reset to baseline** → run **Approach A** (3-step) from the same baseline → compare.

> Everything below is **localhost-only** and in its own compose project
> (`/srv/docker/registry-migration-test/`). Docker treats `localhost:*` registries as insecure, so **no TLS
> and no proxy** are needed.

---

## 0. Isolated test stack

`/srv/docker/registry-migration-test/docker-compose.yml`:
```yaml
services:
  gitlab-test:
    image: gitlab/gitlab-ce:19.1.1-ce.0        # match your target version
    container_name: gitlab-registry-test
    hostname: gitlab-test.local
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://localhost:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2224
        gitlab_rails['initial_root_password'] = 'test-root-password-123'
        prometheus_monitoring['enable'] = false           # keep it light
        # LEGACY registry (filesystem, NO database) = the starting point
        registry_external_url 'http://localhost:5005'
        gitlab_rails['registry_enabled'] = true
        registry_nginx['listen_port'] = 5005
        registry['database'] = { 'enabled' => false }
    ports:
      - "127.0.0.1:8929:8929"      # web/API, localhost only
      - "127.0.0.1:5005:5005"      # registry, localhost only
    shm_size: '256m'
    volumes:
      - test_config:/etc/gitlab
      - test_data:/var/opt/gitlab

volumes:
  test_config:
  test_data:
```
```bash
cd /srv/docker/registry-migration-test
docker compose up -d
# wait until healthy (a few minutes):
until docker exec gitlab-registry-test curl -fsS http://localhost:8929/-/health >/dev/null 2>&1; do sleep 10; done
docker exec gitlab-registry-test gitlab-ctl status | grep registry     # run: registry:
```

---

## 1. Seed a synthetic legacy registry

Pick `R` repos × `T` tags. Start modest (e.g. R=20, T=50 → 1000 tags) so a run is minutes, then scale up
if you want a bigger sample. Uses a small image you already have locally (`postgres:17-alpine`) retagged.

```bash
ROOT_PW='test-root-password-123'
R=20; T=50
SRC=postgres:17-alpine

# personal access token for the API (create via rails)
TOKEN=$(docker exec gitlab-registry-test gitlab-rails runner \
  "t=User.find_by_username('root').personal_access_tokens.create(scopes:['api'],name:'seed',expires_at:1.day.from_now); t.set_token('seedtoken123'); t.save!; puts 'seedtoken123'")

docker login localhost:5005 -u root -p "$ROOT_PW"

for r in $(seq 1 $R); do
  curl -s -H "PRIVATE-TOKEN: seedtoken123" -X POST \
    "http://localhost:8929/api/v4/projects" -d "name=testrepo$r&visibility=private" >/dev/null
  for t in $(seq 1 $T); do
    docker tag  $SRC localhost:5005/root/testrepo$r:v$t
    docker push localhost:5005/root/testrepo$r:v$t
  done
  echo "seeded repo $r/$R"
done

# record the counts you're testing against:
curl -s -H "PRIVATE-TOKEN: seedtoken123" "http://localhost:8929/v2/_catalog" 2>/dev/null | jq '.repositories|length'
echo "tags total ≈ $((R*T))"
```
> Confirm it's still **legacy**:
> `docker exec gitlab-registry-test curl -sI http://localhost:5005/v2/ | grep -i database-enabled` → absent/false.

---

## 2. Baseline snapshot (so both approaches start identical)

```bash
docker compose stop gitlab-test
docker run --rm -v registry-migration-test_test_data:/d -v "$PWD":/b alpine \
  tar czf /b/baseline-data.tgz  -C /d .
docker run --rm -v registry-migration-test_test_config:/d -v "$PWD":/b alpine \
  tar czf /b/baseline-config.tgz -C /d .
docker compose start gitlab-test
ls -lh baseline-*.tgz
```

**Reset-to-baseline helper** (used between the two runs):
```bash
# restore.sh
docker compose down
docker volume rm registry-migration-test_test_data registry-migration-test_test_config
docker volume create registry-migration-test_test_data
docker volume create registry-migration-test_test_config
docker run --rm -v registry-migration-test_test_data:/d -v "$PWD":/b alpine   tar xzf /b/baseline-data.tgz  -C /d
docker run --rm -v registry-migration-test_test_config:/d -v "$PWD":/b alpine tar xzf /b/baseline-config.tgz -C /d
docker compose up -d
until docker exec gitlab-registry-test curl -fsS http://localhost:8929/-/health >/dev/null 2>&1; do sleep 10; done
```

---

## 3. Run Approach B — one-step (bundled Postgres)  ⭐ preferred

Edit `GITLAB_OMNIBUS_CONFIG` in the test compose:
```ruby
registry['database'] = { 'enabled' => false }
registry['storage'] = {
  'filesystem'  => { 'rootdirectory' => '/var/opt/gitlab/gitlab-rails/shared/registry' },
  'maintenance' => { 'readonly' => { 'enabled' => true } }
}
```
```bash
docker compose up -d && docker exec gitlab-registry-test gitlab-ctl reconfigure
docker exec gitlab-registry-test gitlab-ctl registry-database migrate up

# TIME THE IMPORT (this whole window = read-only):
docker exec gitlab-registry-test bash -c 'time gitlab-ctl registry-database import --log-to-stdout' 2>&1 | tee approachB.log
```
Turn DB on + read-only off (flip both booleans), `docker compose up -d && ... reconfigure`. Verify:
```bash
docker exec gitlab-registry-test curl -sI http://localhost:5005/v2/ | grep -i database-enabled   # true
docker exec gitlab-registry-test gitlab-psql -d registry -c "select count(*) from repositories;"
```
**Record:** the `real` time from `approachB.log`, repo/tag count, any errors.

---

## 4. Reset, then run Approach A — 3-step (dedicated Postgres)

```bash
bash restore.sh        # back to identical legacy baseline
```
Add a `registry-db` service to the test compose (postgres:17-alpine, on a `test-internal` network shared
with `gitlab-test`) and point the registry at it with `enabled => false` (see runbook Approach A). Then:
```bash
docker compose up -d && docker exec gitlab-registry-test gitlab-ctl reconfigure

# pre-import runs ONLINE (registry stays read-write) — time it:
docker exec gitlab-registry-test bash -c 'time gitlab-ctl registry-database import --step-one-pre-import' 2>&1 | tee approachA-preimport.log

# final step is the READ-ONLY window — time it separately:
docker exec gitlab-registry-test bash -c 'time gitlab-ctl registry-database import --step-two-import' 2>&1 | tee approachA-final.log
```
Flip `enabled => true`, `docker compose up -d && ... reconfigure`. Verify (query `registry-db`).
**Record:** pre-import `real` time (online), final-step `real` time (**this is the read-only window**), errors.

---

## 5. Results (fill after running)

| Metric | ⭐ Approach B (one-step) | Approach A (3-step) |
|---|---|---|
| Test dataset (repos × tags) | _TBD_ | _same_ |
| Total import wall-clock | _TBD_ | _pre-import + final_ |
| **Read-only window** | _= total import_ | _= final step only_ |
| Per-tag rate (tags ÷ read-only secs) | _TBD_ | _TBD_ |
| Setup effort | one config block | extra container + network |
| Errors / surprises | _TBD_ | _TBD_ |
| Post-import repo count matches? | _TBD_ | _TBD_ |

**Extrapolation to the real 1.8 TB registry:**
- Real tag count ÷ measured per-tag rate = estimated read-only window.
- Fill once you have the real count: `curl -s -u <u>:<p> https://<registry>/v2/_catalog | jq '.repositories|length'` (× avg tags/repo).

---

## 6. Cleanup

```bash
cd /srv/docker/registry-migration-test
docker compose down -v
docker rmi $(docker images 'localhost:5005/*' -q) 2>/dev/null || true
rm -f baseline-*.tgz approach*.log
```

---

## Notes / caveats

- **Localhost + insecure registry** keeps the test free of TLS/proxy — none of the `registry2.amf`/cert
  machinery is involved.
- Retagging one image gives many **tags** sharing blobs — good for exercising **tag/manifest import scaling**
  (the thing that drives import time). For a heavier test, seed from a few different base images.
- Confirm the exact 3-step flags on this version first:
  `docker exec gitlab-registry-test gitlab-ctl registry-database import --help`.
- This is a **mechanism + rate** test; it deliberately does not move 1.8 TB. Extrapolate from the per-tag rate.
