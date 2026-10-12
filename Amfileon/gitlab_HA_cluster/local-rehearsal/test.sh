#!/bin/bash
# End-to-end rehearsal: GitLab on db1 -> changes replicated -> db1 dies -> failover to db2.
#   ./test.sh            run everything (about 15-25 min, mostly GitLab boot time)
#   docker compose down -v   clean up afterwards
set -uo pipefail
cd "$(dirname "$0")"

PASS=0 FAIL=0
say()   { echo; echo "== $*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; PASS=$((PASS+1)); else echo "  FAIL  $d"; FAIL=$((FAIL+1)); fi; }
gap()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  INFO  $d: present (a sweep caught it)"; else echo "  GAP   $d: missing on db2 (expected: not synced before db1 died)"; fi; }
die()   { echo "ABORT: $*"; exit 1; }

cl()    { docker exec client "$@"; }
api()   { local p=$1; shift; cl curl -fsS -H "PRIVATE-TOKEN: $TOKEN" "http://gitlab.local-test.amf/api/v4$p" "$@"; }
etcd()  { docker compose exec -T etcd etcdctl "$@"; }
ready() { docker exec "gitlab-$1" curl -fsS -m 5 -H 'Host: gitlab.local-test.amf' http://localhost/-/readiness; }
wait_ready() {
  echo -n "  waiting for GitLab on $1 "
  for _ in $(seq 1 90); do ready "$1" >/dev/null 2>&1 && { echo " ready"; return 0; }; echo -n "."; sleep 10; done
  echo " timed out"; return 1
}
db2_main() { docker exec hasync git -c safe.directory='*' --git-dir="/n/db2/data/git-data/repositories/$RP" rev-parse refs/heads/main 2>/dev/null; }

# ---------------------------------------------------------------------------
say "0. Setup: secrets, images, Postgres (Patroni stand-in), etcd"
if [ ! -f .env ]; then
  cat > .env <<EOF
GITLAB_ROOT_PASSWORD=$(openssl rand -hex 12)
PG_SUPERUSER_PASSWORD=$(openssl rand -hex 12)
GITLAB_DB_PASSWORD=$(openssl rand -hex 12)
REGISTRY_DB_PASSWORD=$(openssl rand -hex 12)
DB_KEY_BASE=$(openssl rand -hex 64)
SECRET_KEY_BASE=$(openssl rand -hex 64)
OTP_KEY_BASE=$(openssl rand -hex 64)
SWEEP_INTERVAL=600
EOF
fi
docker compose build -q || die "build failed"
docker compose up -d pg etcd client || die "compose up failed"
for _ in $(seq 1 30); do etcd put /amf/gitlab/active db1 >/dev/null 2>&1 && break; sleep 2; done
check "etcd active flag = db1" bash -c '[ "$(docker compose exec -T etcd etcdctl get --print-value-only /amf/gitlab/active)" = db1 ]'

# ---------------------------------------------------------------------------
say "1. Start GitLab on db1 and seed data"
docker compose up -d --no-deps gitlab-db1
wait_ready db1 || die "db1 never became ready (docker logs gitlab-db1)"

TOKEN=$(docker exec gitlab-db1 gitlab-rails runner "
  u = User.find_by_username('root')
  t = u.personal_access_tokens.create!(name: 'ha-rehearsal', expires_at: 30.days.from_now,
        scopes: %w[api read_repository write_repository read_registry write_registry])
  puts t.token" 2>/dev/null | tail -1)
[[ "$TOKEN" == glpat-* ]] || die "could not create token: $TOKEN"

PID=$(api /projects -X POST -d name=demo -d visibility=public | jq -r .id)
[[ "$PID" =~ ^[0-9]+$ ]] || die "project create failed"
HASH=$(cl sh -c "printf %s $PID | sha256sum | cut -d' ' -f1")
RP="@hashed/${HASH:0:2}/${HASH:2:2}/$HASH.git"

cl sh -c "rm -rf /w && git init -q -b main /w && cd /w && git config user.name t && git config user.email t@amf \
  && git remote add origin http://root:$TOKEN@gitlab.local-test.amf/root/demo.git \
  && echo A > a.txt && git add . && git commit -qm A && git push -q origin main" || die "push A failed"
SHA_A=$(cl git -C /w rev-parse HEAD)

cl sh -c 'echo upload-one > /tmp/u1.txt'
UP1=$(api "/projects/$PID/uploads" -F file=@/tmp/u1.txt)
UP1_ID=$(echo "$UP1" | jq -r .id)
api "/projects/$PID/issues" -X POST --data-urlencode "title=issue one" \
  --data-urlencode "description=$(echo "$UP1" | jq -r .markdown)" >/dev/null

cl crane auth login registry.local-test.amf -u root -p "$TOKEN" >/dev/null
cl sh -c 'echo v1 > /tmp/v1.txt && tar -C /tmp -cf /tmp/l1.tar v1.txt && crane append --insecure -f /tmp/l1.tar -t registry.local-test.amf/root/demo:v1' >/dev/null
check "seed: commit A pushed"        test -n "$SHA_A"
check "seed: upload one readable"    api "/projects/$PID/uploads/$UP1_ID"
check "seed: image demo:v1 pullable" cl crane digest --insecure registry.local-test.amf/root/demo:v1

# ---------------------------------------------------------------------------
say "2. Start replication db1 -> db2, create db2 standby (stopped)"
docker compose up -d hasync
for _ in $(seq 1 60); do [ -n "$(etcd get --print-value-only /amf/gitlab/last_full_sync 2>/dev/null)" ] && break; sleep 2; done
docker compose create gitlab-db2 >/dev/null 2>&1
check "initial full sync finished"   bash -c '[ -n "$(docker compose exec -T etcd etcdctl get --print-value-only /amf/gitlab/last_full_sync)" ]'
check "db2 has commit A on disk"     bash -c "[ \"\$(docker exec hasync git -c safe.directory='*' --git-dir=/n/db2/data/git-data/repositories/$RP rev-parse refs/heads/main)\" = $SHA_A ]"
check "db2 standby created, not running" bash -c '[ "$(docker inspect -f {{.State.Status}} gitlab-db2)" = created ]'

# ---------------------------------------------------------------------------
say "3. Activity on db1 between sweeps"
cl sh -c "cd /w && echo B > b.txt && git add . && git commit -qm B && git push -q origin main"
SHA_B=$(cl git -C /w rev-parse HEAD)
t0=$(date +%s); lag=none
for _ in $(seq 1 30); do [ "$(db2_main)" = "$SHA_B" ] && { lag=$(( $(date +%s) - t0 )); break; }; sleep 1; done
echo "  repo lag via post-receive hook: ${lag}s"
check "commit B reached db2 within 30 s (hook)" test "$lag" != none

cl sh -c 'echo upload-two > /tmp/u2.txt'
UP2=$(api "/projects/$PID/uploads" -F file=@/tmp/u2.txt)
UP2_ID=$(echo "$UP2" | jq -r .id)
api "/projects/$PID/issues" -X POST --data-urlencode "title=issue two" \
  --data-urlencode "description=$(echo "$UP2" | jq -r .markdown)" >/dev/null
cl sh -c 'echo v2 > /tmp/v2.txt && tar -C /tmp -cf /tmp/l2.tar v2.txt && crane append --insecure -f /tmp/l2.tar -t registry.local-test.amf/root/demo:v2' >/dev/null

# ---------------------------------------------------------------------------
say "4. db1 dies (GitLab and its sync job), fail over to db2"
docker kill gitlab-db1 hasync >/dev/null
./failover.sh db2 || die "failover failed (docker logs gitlab-db2)"

# ---------------------------------------------------------------------------
say "5. Verify gitlab.local-test.amf on db2"
DB2_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "amf-front").IPAddress}}' gitlab-db2)
check "gitlab.local-test.amf resolves to db2"            bash -c "docker exec client getent hosts gitlab.local-test.amf | grep -q '^$DB2_IP '"
check "API login with existing token"         api /user
check "clone has commit B (A + B)"            bash -c "[ \"\$(docker exec client sh -c 'rm -rf /c && git clone -q http://root:$TOKEN@gitlab.local-test.amf/root/demo.git /c && git -C /c rev-parse HEAD')\" = $SHA_B ]"
check "issue one + issue two exist (DB)"      bash -c "[ \"\$(docker exec client curl -fsS -H 'PRIVATE-TOKEN: $TOKEN' http://gitlab.local-test.amf/api/v4/projects/$PID/issues | jq length)\" = 2 ]"
check "upload one readable"                   api "/projects/$PID/uploads/$UP1_ID"
check "image demo:v1 pullable"                cl crane pull --insecure registry.local-test.amf/root/demo:v1 /tmp/v1.tar
check "push commit C to db2"                  cl sh -c "cd /w && echo C > c.txt && git add . && git commit -qm C && git push -q origin main"
gap   "upload two"                            api "/projects/$PID/uploads/$UP2_ID"
gap   "image demo:v2"                         cl crane pull --insecure registry.local-test.amf/root/demo:v2 /tmp/v2.tar

# ---------------------------------------------------------------------------
say "6. Split-brain guard: db1 comes back while db2 is active"
docker start gitlab-db1 >/dev/null
sleep 20
check "db1 refused to start GitLab"           bash -c "docker logs gitlab-db1 2>&1 | grep -q 'REFUSING to start GitLab on db1'"
check "db1 never started GitLab services"     bash -c "[ \"\$(docker logs gitlab-db1 2>&1 | awk '/REFUSING/{f=1} f' | grep -cE 'Thank you for using|Starting services')\" = 0 ]"
check "db2 still serving"                     ready db2
docker update --restart=no gitlab-db1 >/dev/null; docker stop gitlab-db1 >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "== RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
