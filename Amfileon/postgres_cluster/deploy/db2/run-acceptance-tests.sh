#!/usr/bin/env bash
# run-acceptance-tests.sh — automated version of postgres_cluster/docs/test-plan.md
#
# Run this on db1, db2, or prod3 — it auto-detects which host it's on via `hostname` and
# picks the right mode:
#   - db1 / db2:  full suite (Sections A, B, C, D, F against Postgres + etcd, via the VIP).
#   - prod3:      referee-only mode — Section E only, since prod3 has no Postgres to test.
#                 This stops/starts prod3's OWN etcd voter (matching how the referee test
#                 was actually run against the live cluster), not a stand-in on another host.
#
# Reads the Postgres superuser password from ./.env on db1/db2 so nothing is typed
# interactively, and always talks to "the current primary" via the virtual IP (10.10.10.18)
# rather than assuming a fixed host — so it stays correct across failovers.
#
# Safe by default: only runs Sections A, B, F (read-only / self-cleaning, zero risk).
# Sections C, D, E actually change cluster state (a real ~30s interruption for D) and are
# gated behind --include-disruptive plus a typed confirmation — never run by accident.
#
# To exercise the full test-run-2026-07-27.md doc end to end, non-interactively, with no
# SSH hopping between hosts: run this once on whichever host is CURRENTLY THE REPLICA
# (check with `patronictl list`) — Section C's switchover promotes it, so Section D's
# self-check then exercises the failover in the same run — then once more on prod3 for
# Section E. Two single-host invocations, zero manual steps inside either one.
#
# Usage:
#   sudo ./run-acceptance-tests.sh                       # safe sections only
#   sudo ./run-acceptance-tests.sh --include-disruptive  # full suite, will prompt to confirm
#   sudo ./run-acceptance-tests.sh --include-disruptive --yes  # skip the prompt too (CI use)

set -uo pipefail   # deliberately NOT -e: several checks below expect a command to fail

# ---------- host detection ----------
HOST="$(hostname)"
MODE=full
case "$HOST" in
  db1) PG_SVC=pg1; DEPLOY_DIR=/srv/docker/pg-cluster-instance-1; IFACE=ens259f0
       ETCD_URL=https://10.10.10.20:12379; CLIENT_CRT=etcd1.client.crt; CLIENT_KEY=etcd1.client.key ;;
  db2) PG_SVC=pg2; DEPLOY_DIR=/srv/docker/pg-cluster-instance-2; IFACE=ens259f0np0
       ETCD_URL=https://10.10.10.21:12379; CLIENT_CRT=etcd2.client.crt; CLIENT_KEY=etcd2.client.key ;;
  prod3) MODE=referee-only; DEPLOY_DIR=/srv/docker/pg-cluster-instance-3
         ETCD_URL=https://10.10.10.13:12379; CLIENT_CRT=etcd3.client.crt; CLIENT_KEY=etcd3.client.key
         PEER_IP=10.10.10.20 ;;   # ask db1's etcd for cluster health while prod3's own voter is down
  *)   echo "This host ('$HOST') is not part of the cluster — run this on db1, db2, or prod3." >&2; exit 1 ;;
esac

VIP=10.10.10.18
PGPORT=15432
INCLUDE_DISRUPTIVE=false
SKIP_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --include-disruptive) INCLUDE_DISRUPTIVE=true ;;
    --yes) SKIP_CONFIRM=true ;;
  esac
done

cd "$DEPLOY_DIR" || { echo "Can't cd to $DEPLOY_DIR"; exit 1; }

PASS=0; FAIL=0; RESULTS=()
record() { # record "<label>" <0-or-1 where 0=pass>
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); RESULTS+=("PASS  $1"); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); echo "  FAIL  $1"; fi
}
summarize_and_exit() {
  echo
  echo "=========================================="
  echo " Result: $PASS passed, $FAIL failed"
  echo "=========================================="
  for r in "${RESULTS[@]}"; do echo "  $r"; done
  [ "$FAIL" -eq 0 ]
  exit $?
}

# ===========================================================================
# prod3: referee-only mode. No Postgres here, so only Section E applies.
# ===========================================================================
if [ "$MODE" = referee-only ]; then
  echo "=== running on $HOST (referee-only mode) ==="
  echo

  if [ "$INCLUDE_DISRUPTIVE" != true ]; then
    echo "Nothing to do here in safe mode — prod3 has no Postgres, so Sections A/B/F don't"
    echo "apply. Re-run with --include-disruptive to exercise Section E (stop/start this"
    echo "host's own etcd voter and confirm the cluster stays quorate)."
    exit 0
  fi

  echo "Section E will stop this host's own etcd voter for about a minute."
  if [ "$SKIP_CONFIRM" != true ]; then
    read -r -p "Type 'yes' to proceed, anything else to skip: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "Skipped."; exit 0; }
  fi

  # Uses `docker run` with the same etcd image already pulled for the compose service,
  # rather than `docker compose exec` into it — that container is what we're about to
  # stop, so we need a way to query the cluster that doesn't depend on it being up.
  ETCDCTL_IMG=quay.io/coreos/etcd:v3.5.21
  ETCDCTL_VIA() { # ETCDCTL_VIA <endpoint-ip> <etcdctl-args...>
    local ip=$1; shift
    docker run --rm --network host -v "$DEPLOY_DIR/certs:/certs:ro" "$ETCDCTL_IMG" \
      etcdctl --endpoints="https://$ip:12379" --cacert=/certs/ca.crt \
      --cert=/certs/"$CLIENT_CRT" --key=/certs/"$CLIENT_KEY" "$@"
  }

  echo
  echo "--- Section E: referee resilience (stopping prod3's own etcd voter) ---"
  HEALTH0=$(ETCDCTL_VIA 10.10.10.13 endpoint health --cluster 2>&1)
  [ "$(echo "$HEALTH0" | grep -c 'is healthy')" -eq 3 ]
  record "E0: starting from 3/3 healthy" $?

  docker compose stop etcd >/dev/null 2>&1
  sleep 3
  HEALTH1=$(ETCDCTL_VIA "$PEER_IP" endpoint health --cluster 2>&1)
  [ "$(echo "$HEALTH1" | grep -c 'is healthy')" -eq 2 ]
  record "E1-E3: db1/db2 still healthy with prod3's voter down (2/3 quorate)" $?

  docker compose start etcd >/dev/null 2>&1
  sleep 10
  HEALTH2=$(ETCDCTL_VIA 10.10.10.13 endpoint health --cluster 2>&1)
  [ "$(echo "$HEALTH2" | grep -c 'is healthy')" -eq 3 ]
  record "E4: referee cluster restored to 3/3 healthy" $?

  summarize_and_exit
fi

# ===========================================================================
# db1 / db2: full suite
# ===========================================================================
[ -f .env ] || { echo ".env not found in $DEPLOY_DIR"; exit 1; }
PGPASSWORD_SUPERUSER="$(grep -E '^PGPASSWORD_SUPERUSER=' .env | cut -d= -f2-)"
[ -n "$PGPASSWORD_SUPERUSER" ] || { echo "PGPASSWORD_SUPERUSER not found in .env"; exit 1; }
export PGPASSWORD="$PGPASSWORD_SUPERUSER"

DC() { docker compose exec -T -e PGPASSWORD="${PGPASSWORD:-}" "$@"; }   # exec into this host's own containers
# `docker compose exec` does NOT inherit the caller's environment — without -e PGPASSWORD above,
# psql inside the container finds no password, prompts on stdin, and hangs forever with no visible
# error (since callers redirect stdout/stderr away). </dev/null below is a second line of defense:
# if PGPASSWORD is ever empty, psql fails fast ("no password supplied") instead of hanging again.
PSQL_VIP()     { DC "$PG_SVC" psql -h "$VIP"  -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 "$@" </dev/null; }
PSQL_HOST()    { local ip=$1; shift; DC "$PG_SVC" psql -h "$ip" -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 "$@" </dev/null; }
ETCDCTL() {
  DC etcd etcdctl --endpoints="$ETCD_URL" --cacert=/certs/ca.crt \
    --cert=/certs/"$CLIENT_CRT" --key=/certs/"$CLIENT_KEY" "$@"
}

# Ask patronictl for the cluster state as JSON and pull out the fields we need with python3
# (guaranteed present in the Spilo image, so no dependency on what's installed on the host).
cluster_json() { DC "$PG_SVC" patronictl list -f json 2>/dev/null; }
py() { DC "$PG_SVC" python3 -c "$1"; }

get_field() { # get_field <role: Leader|Replica> <field: Member|Host>
  # patronictl's JSON 'Host' field is 'ip:port' combined, not a bare IP — split it off here so
  # every caller gets a plain address usable with psql -h. Harmless no-op for 'Member' (no colon).
  cluster_json | py "
import json,sys
for m in json.load(sys.stdin):
    if m.get('Role') == '$1':
        print(m.get('$2', '').split(':')[0])
"
}

echo "=== running on $HOST (service $PG_SVC), deploy dir $DEPLOY_DIR ==="
echo

# ---------------------------------------------------------------------------
echo "--- Section A: health checks ---"
MEMBERS=$(ETCDCTL member list -w table 2>/dev/null)
echo "$MEMBERS" | grep -q "started" && [ "$(echo "$MEMBERS" | grep -c started)" -eq 3 ]
record "A1: 3 etcd members present and started" $?

HEALTH=$(ETCDCTL endpoint health --cluster 2>&1)
[ "$(echo "$HEALTH" | grep -c 'is healthy')" -eq 3 ]
record "A1: all 3 etcd endpoints healthy" $?

LEADER=$(get_field Leader Member); REPLICA=$(get_field Replica Member)
REPLICA_IP=$(get_field Replica Host)
[ -n "$LEADER" ] && [ -n "$REPLICA" ] && [ "$LEADER" != "$REPLICA" ]
record "A2: exactly one Leader ($LEADER) and one Replica ($REPLICA)" $?
echo "     current leader: $LEADER   current replica: $REPLICA ($REPLICA_IP)"

if [ "$HOST" = "$LEADER" ]; then
  ip addr show "$IFACE" | grep -q "$VIP"
  record "A3: VIP present on this host, which is the current leader" $?
else
  ! ip addr show "$IFACE" | grep -q "$VIP"
  record "A3: VIP correctly absent from this host (not the leader)" $?
fi
echo

# ---------------------------------------------------------------------------
echo "--- Section B: data path (self-cleaning) ---"
PSQL_VIP -c "CREATE TABLE IF NOT EXISTS acceptance_test(id int); TRUNCATE acceptance_test; INSERT INTO acceptance_test VALUES (1);" >/dev/null 2>&1
record "B1: write succeeded on the current leader (via VIP)" $?

ROW=$(PSQL_HOST "$REPLICA_IP" -tAc "SELECT count(*) FROM acceptance_test;" 2>/dev/null)
[ "$ROW" = "1" ]
record "B2: row replicated to the standby ($REPLICA)" $?

PSQL_HOST "$REPLICA_IP" -c "INSERT INTO acceptance_test VALUES (2);" >/dev/null 2>&1
[ $? -ne 0 ]
record "B3: standby correctly REJECTED a write" $?

PSQL_VIP -c "DROP TABLE IF EXISTS acceptance_test;" >/dev/null 2>&1
echo

# ---------------------------------------------------------------------------
echo "--- Section F: security enforcement ---"
curl -sk "$ETCD_URL/v3/kv/range" -d '{"key":"AA=="}' >/tmp/f1_out 2>/dev/null
F1_EXIT=$?; F1_SIZE=$(wc -c </tmp/f1_out)
[ "$F1_EXIT" -ne 0 ] && [ "$F1_SIZE" -eq 0 ]
record "F1: unauthenticated etcd request refused" $?
rm -f /tmp/f1_out

PGPASSWORD=wrong-password DC "$PG_SVC" psql -h "$VIP" -p "$PGPORT" -U postgres -c "select 1;" </dev/null >/tmp/f2_out 2>&1
grep -q "password authentication failed" /tmp/f2_out
record "F2: wrong password refused" $?
rm -f /tmp/f2_out
echo

# ---------------------------------------------------------------------------
if [ "$INCLUDE_DISRUPTIVE" = true ]; then
  echo "--- Disruptive sections requested (C, D, E) ---"
  echo "Section D will stop the CURRENT PRIMARY ($LEADER) for a real ~30 second interruption."
  echo "Section E will stop this host's own etcd voter for about a minute."
  if [ "$SKIP_CONFIRM" != true ]; then
    read -r -p "Type 'yes' to proceed with the disruptive tests, anything else to skip them: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "Skipped."; INCLUDE_DISRUPTIVE=false; }
  fi
fi

if [ "$INCLUDE_DISRUPTIVE" = true ]; then
  echo
  echo "--- Section C: planned handover ---"
  DC "$PG_SVC" patronictl switchover --force >/dev/null 2>&1
  sleep 5
  NEW_LEADER=$(get_field Leader Member)
  [ -n "$NEW_LEADER" ] && [ "$NEW_LEADER" != "$LEADER" ]
  record "C1: switchover moved leadership away from $LEADER (now $NEW_LEADER)" $?
  LEADER="$NEW_LEADER"; REPLICA_IP=$(get_field Replica Host)

  PSQL_VIP -tAc "select pg_is_in_recovery();" 2>/dev/null | grep -qx f
  record "C2: live write path via VIP confirms new leader is accepting writes" $?

  echo
  echo "--- Section D: unplanned failure ---"
  if [ "$HOST" = "$LEADER" ]; then
    echo "Stopping local $PG_SVC (current leader) — timing recovery..."
    # patronictl only runs inside the Spilo container we're about to stop, so it can't be used
    # to poll DURING the outage. Query etcd directly instead — it keeps running throughout
    # Section D (only Postgres gets stopped here, not etcd) and holds the leader key itself.
    LEADER_KEY=$(ETCDCTL get "" --prefix --keys-only 2>/dev/null | grep '/leader$' | head -1)
    START=$(date +%s)
    docker compose stop "$PG_SVC" >/dev/null 2>&1
    CUR=""
    for _ in $(seq 1 20); do
      sleep 3
      if [ -n "$LEADER_KEY" ]; then
        CUR=$(ETCDCTL get "$LEADER_KEY" --print-value-only 2>/dev/null)
      fi
      [ -n "$CUR" ] && [ "$CUR" != "$LEADER" ] && break
    done
    ELAPSED=$(( $(date +%s) - START ))
    [ -n "$CUR" ] && [ "$CUR" != "$LEADER" ]
    record "D1-D2: automatic promotion completed in ~${ELAPSED}s" $?
    docker compose start "$PG_SVC" >/dev/null 2>&1
    sleep 15
    ROLE_NOW=$(cluster_json | py "
import json,sys
for m in json.load(sys.stdin):
    if m.get('Member') == '$HOST':
        print(m.get('Role'))
")
    [ "$ROLE_NOW" = "Replica" ]
    record "D5: old primary rejoined as Replica, not a second Leader" $?
  else
    echo "  Skipped — this host ($HOST) is not the current leader ($LEADER)."
    echo "  Run this script with --include-disruptive on $LEADER instead to exercise Section D."
  fi

  echo
  echo "--- Section E: referee resilience (stopping this host's own etcd voter) ---"
  docker compose stop etcd >/dev/null 2>&1
  sleep 3
  PSQL_VIP -c "select 1;" >/dev/null 2>&1
  record "E1-E2: database still fully operational with 1 of 3 voters down" $?
  docker compose start etcd >/dev/null 2>&1
  sleep 10
  HEALTH2=$(ETCDCTL endpoint health --cluster 2>&1)
  [ "$(echo "$HEALTH2" | grep -c 'is healthy')" -eq 3 ]
  record "E4: referee cluster restored to 3/3 healthy" $?
fi

summarize_and_exit
