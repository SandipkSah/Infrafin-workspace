#!/bin/bash
# Broad failure scenarios. Run AFTER ./test.sh (expects: db2 active, db1 stopped).
#   7  failover.sh refuses while the other node is still running
#   8  sync job dead -> staleness visible; restart -> fresh again
#   9  planned failback db2 -> db1 (no data loss expected)
#  10  Postgres connection drop / leader switch under a running GitLab
#  11  etcd down: running GitLab keeps serving, a (re)starting one refuses
#  12  db1 crashes during a stream of pushes -> failover to db2 (3rd transition), git fsck
#  13  hung node (paused) -> forced failover -> node wakes up and self-fences
set -uo pipefail
cd "$(dirname "$0")"

PASS=0 FAIL=0
say()   { echo; echo "== $*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "  PASS  $d"; PASS=$((PASS+1)); else echo "  FAIL  $d"; FAIL=$((FAIL+1)); fi; }
info()  { echo "  INFO  $*"; }
die()   { echo "ABORT: $*"; echo "== RESULT so far: $PASS passed, $FAIL failed"; exit 1; }

H=gitlab.local-test.amf
cl()    { docker exec client "$@"; }
api()   { local p=$1; shift; cl curl -fsS -m 10 -H "PRIVATE-TOKEN: $TOKEN" "http://$H/api/v4$p" "$@"; }
etcd()  { docker compose exec -T etcd etcdctl "$@"; }
flag()  { etcd get --print-value-only /amf/gitlab/active 2>/dev/null; }
ready() { docker exec "gitlab-$1" curl -fsS -m 5 -H "Host: $H" http://localhost/-/readiness; }
wait_ready() {
  echo -n "  waiting for GitLab on $1 "
  for _ in $(seq 1 90); do ready "$1" >/dev/null 2>&1 && { echo " ready"; return 0; }; echo -n "."; sleep 10; done
  echo " timed out"; return 1
}
# read a node's repo straight from its volume (works while the sync job is dead or paused)
diskgit()   { local n=$1; shift; docker run --rm --entrypoint git -v "gitlab-ha-rehearsal_${n}_data:/d:ro" gitlab-ha-rehearsal-hasync \
                -c safe.directory='*' --git-dir="/d/git-data/repositories/$RP" "$@"; }
disk_main() { diskgit "$1" rev-parse refs/heads/main 2>/dev/null; }
wait_disk() { # node sha timeout
  for _ in $(seq 1 "$3"); do [ "$(disk_main "$1")" = "$2" ] && return 0; sleep 1; done; return 1
}
hb_age()    { local hb; hb=$(etcd get --print-value-only /amf/gitlab/sync_heartbeat 2>/dev/null); echo $(( $(date +%s) - ${hb:-0} )); }
last_sync() { etcd get --print-value-only /amf/gitlab/last_full_sync 2>/dev/null || echo 0; }
wait_new_sweep() { # previous-value timeout
  for _ in $(seq 1 "$2"); do [ "$(last_sync)" != "$1" ] && return 0; sleep 2; done; return 1
}
commit_push() { cl sh -c "cd /w && echo $1 > $1.txt && git add . && git commit -qm $1 && git push -q origin main" && cl git -C /w rev-parse HEAD; }

# ---------------------------------------------------------------------------
say "Prep: state from test.sh, fresh token, rebuilt sync job"
[ "$(flag)" = db2 ] || die "expected active flag db2 (run ./test.sh first)"
ready db2 >/dev/null 2>&1 || die "db2 not serving"
TOKEN=$(docker exec gitlab-db2 gitlab-rails runner "
  u = User.find_by_username('root')
  t = u.personal_access_tokens.create!(name: 'ha-broad', expires_at: 30.days.from_now,
        scopes: %w[api read_repository write_repository read_registry write_registry])
  puts t.token" 2>/dev/null | tail -1)
[[ "$TOKEN" == glpat-* ]] || die "could not create token"
PID=$(api "/projects?search=demo" | jq -r '.[0].id')
HASH=$(cl sh -c "printf %s $PID | sha256sum | cut -d' ' -f1")
RP="@hashed/${HASH:0:2}/${HASH:2:2}/$HASH.git"
cl sh -c "cd /w && git remote set-url origin http://root:$TOKEN@$H/root/demo.git && git pull -q --rebase origin main" || die "client repo sync failed"
docker compose build -q hasync
info "project $PID, repo $RP"

# ---------------------------------------------------------------------------
say "7. failover.sh refuses while the other node is running"
check "failover.sh db1 exits non-zero (db2 running)"  bash -c '! ./failover.sh db1'
check "active flag unchanged (db2)"                    bash -c '[ "$(docker compose exec -T etcd etcdctl get --print-value-only /amf/gitlab/active)" = db2 ]'
check "db2 still serving"                              ready db2

# ---------------------------------------------------------------------------
say "8. Sync job dead -> staleness visible -> restart -> fresh"
docker rm -f hasync >/dev/null 2>&1
SHA_D=$(commit_push D)
sleep 15
info "heartbeat age with sync job dead: $(hb_age)s"
check "staleness detectable (heartbeat older than 30 s)"   bash -c "[ $(hb_age) -gt 30 ]"
check "db1 copy is behind (commit D not there)"             bash -c "[ \"$(disk_main db1)\" != $SHA_D ]"
PREV=$(last_sync)
docker compose up -d hasync >/dev/null 2>&1
check "sync job back: full sweep db2 -> db1 ran"            wait_new_sweep "$PREV" 120
check "heartbeat fresh again (< 20 s)"                      bash -c "[ $(hb_age) -lt 20 ]"
check "db1 copy caught up (commit D)"                       wait_disk db1 "$SHA_D" 30
SHA_E=$(commit_push E)
check "new push on db2 reaches db1 via hook (< 30 s)"       wait_disk db1 "$SHA_E" 30

# ---------------------------------------------------------------------------
say "9. Planned failback db2 -> db1 (expect zero loss)"
cl sh -c 'echo upload-three > /tmp/u3.txt'
UP3_ID=$(api "/projects/$PID/uploads" -F file=@/tmp/u3.txt | jq -r .id)
docker stop gitlab-db2 >/dev/null                       # graceful stop of the active node
PREV=$(last_sync); docker restart hasync >/dev/null      # final full sweep from the stopped node
check "final sweep db2 -> db1 after stop"               wait_new_sweep "$PREV" 120
./failover.sh db1 || die "failback failed (docker logs gitlab-db1)"
check "flag = db1"                                      bash -c '[ "$(docker compose exec -T etcd etcdctl get --print-value-only /amf/gitlab/active)" = db1 ]'
check "clone on db1 has commit E"                       bash -c "[ \"\$(docker exec client sh -c 'rm -rf /c && git clone -q http://root:$TOKEN@$H/root/demo.git /c && git -C /c rev-parse HEAD')\" = $SHA_E ]"
check "upload three (made on db2) readable on db1"      api "/projects/$PID/uploads/$UP3_ID"
check "image demo:v1 pullable on db1"                   cl crane pull --insecure registry.local-test.amf/root/demo:v1 /tmp/v1.tar
check "push on db1 works"                               commit_push F
docker start gitlab-db2 >/dev/null; sleep 20
check "db2 restart refused by guard"                    bash -c "docker logs --since 40s gitlab-db2 2>&1 | grep -q 'REFUSING to start GitLab on db2'"
docker update --restart=no gitlab-db2 >/dev/null; docker stop gitlab-db2 >/dev/null 2>&1

# ---------------------------------------------------------------------------
say "10. Postgres connection drop (Patroni leader switch stand-in) under running db1"
STARTED=$(docker inspect -f '{{.State.StartedAt}}' gitlab-db1)
docker compose restart pg >/dev/null 2>&1
t0=$(date +%s); ok=no
for _ in $(seq 1 60); do api /user >/dev/null 2>&1 && { ok=yes; break; }; sleep 2; done
info "API back $(( $(date +%s) - t0 ))s after Postgres restart"
check "GitLab reconnected without restart"              test $ok = yes
check "push after reconnect"                            commit_push G
check "db1 GitLab container not restarted"              bash -c "[ \"\$(docker inspect -f {{.State.StartedAt}} gitlab-db1)\" = $STARTED ]"

# ---------------------------------------------------------------------------
say "11. etcd down"
docker compose stop etcd >/dev/null 2>&1
sleep 40
check "running db1 keeps serving with etcd down (40 s)" ready db1
check "push still works with etcd down"                 commit_push H
check "sync job pauses (direction unknown)"             bash -c "docker logs --since 40s hasync 2>&1 | grep -q 'active node unknown'"
docker restart gitlab-db1 >/dev/null
sleep 25
check "restarting db1 refuses while etcd is down"       bash -c "docker logs --since 30s gitlab-db1 2>&1 | grep -q 'REFUSING.*etcd unreachable'"
docker compose start etcd >/dev/null 2>&1
wait_ready db1 && check "db1 starts by itself once etcd is back" true || check "db1 starts by itself once etcd is back" false

# ---------------------------------------------------------------------------
say "12. db1 crashes during a stream of pushes -> failover to db2"
cl sh -c "rm -f /tmp/stop /tmp/acked /tmp/n; cd /w && git pull -q --rebase origin main"
docker exec -d client sh -c 'cd /w; i=0; while [ ! -f /tmp/stop ]; do i=$((i+1)); echo $i >> loop.txt; git add loop.txt; git commit -qm "loop $i"; if git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=5 push -q origin main 2>/dev/null; then git rev-parse HEAD > /tmp/acked; echo $i > /tmp/n; fi; sleep 0.5; done'
sleep 8
docker kill gitlab-db1 hasync >/dev/null               # the db1 host dies, sync job included
cl touch /tmp/stop; sleep 3
ACKED=$(cl cat /tmp/acked); N=$(cl cat /tmp/n)
info "pushes acknowledged by db1 before the crash: $N"
./failover.sh db2 || die "failover to db2 failed"
DB2_HEAD=$(disk_main db2)
LOST=$(cl git -C /w rev-list --count "$DB2_HEAD..$ACKED" 2>/dev/null || echo "?")
info "acknowledged pushes missing on db2: $LOST (expected 0-few: those inside the hook lag)"
check "git fsck clean on db2's copy"                    diskgit db2 fsck --no-dangling
check "db2 HEAD is an ancestor of last acked push"      cl git -C /w merge-base --is-ancestor "$DB2_HEAD" "$ACKED"
check "clone from db2 works"                            cl sh -c "rm -rf /c && git clone -q http://root:$TOKEN@$H/root/demo.git /c"
cl sh -c "cd /w && git fetch -q origin && git reset -q --hard origin/main"
check "push on db2 works (3rd transition)"              commit_push I

# ---------------------------------------------------------------------------
say "13. Hung node: db2 freezes -> forced failover to db1 -> db2 wakes up and self-fences"
docker update --restart=always gitlab-db1 >/dev/null
PREV=$(last_sync); docker compose up -d hasync >/dev/null 2>&1   # sync now runs db2 -> db1
wait_new_sweep "$PREV" 120 || info "no fresh sweep before freeze"
SHA_J=$(commit_push J); wait_disk db1 "$SHA_J" 30
docker pause gitlab-db2 hasync >/dev/null
check "failover.sh refuses without --force (hung node counts as running)" bash -c '! ./failover.sh db1'
./failover.sh db1 --force || die "forced failover failed"
check "db1 serving, has commit J"                       bash -c "[ \"\$(docker exec client sh -c 'rm -rf /c && git clone -q http://root:$TOKEN@$H/root/demo.git /c && git -C /c rev-parse HEAD')\" = $SHA_J ]"
docker unpause gitlab-db2 hasync >/dev/null
t0=$(date +%s); fenced=no
for _ in $(seq 1 60); do ready db2 >/dev/null 2>&1 || { fenced=yes; break; }; sleep 2; done
info "db2 kept serving for $(( $(date +%s) - t0 ))s after waking up (split-brain window)"
check "db2 self-fenced (stopped serving)"               test $fenced = yes
check "db2 logged the fence"                            bash -c "docker logs gitlab-db2 2>&1 | grep -q 'active node changed'"
sleep 40
check "db2 stays down (guard refuses on restart)"       bash -c "! docker exec gitlab-db2 curl -fsS -m 5 -H 'Host: $H' http://localhost/-/readiness"
check "db1 still serving, push works"                   commit_push K
docker update --restart=no gitlab-db2 >/dev/null; docker stop gitlab-db2 >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "== RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
