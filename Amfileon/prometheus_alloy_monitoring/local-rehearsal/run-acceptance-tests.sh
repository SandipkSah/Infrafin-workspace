#!/usr/bin/env bash
# Acceptance tests for the agreed monitoring plan (Alloy → Prometheus db1 + db2, option-A alerting).
#
#   ./setup.sh && docker compose up -d --build
#   ./run-acceptance-tests.sh            # OUTAGE=600 by default (seconds db1 stays down in test 6)
#   docker compose down -v
#
# Stops and starts containers to simulate failures; leaves the stack healthy at the end.
# Takes ~20 minutes, mostly the db1 outage in test 6.
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

OUTAGE=${OUTAGE:-600}
HOSTS=(db1 db2 cpu1 cpu2 gpu1 prod3 prod4)
SCRAPE=10            # Alloy scrape_interval
MAX_GAP=$((SCRAPE * 2 + 5))
PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────────────────────
# Everything runs from the client container ("an operator's machine on the LAN").
# </dev/null stops `docker compose exec` from swallowing the script's stdin.
cx()   { docker compose exec -T client "$@" </dev/null; }
c()    { cx curl -sS -m 10 "$@"; }
prom() { local n=$1; shift; c --cacert /certs/ca.pem -u "grafana:$GRAFANA_DS_PASSWORD" "https://$n.prometheus.amf$1" "${@:2}"; }
# q <db1|db2> <promql> → first value
q()    { prom "$1" /api/v1/query --data-urlencode "query=$2" | jq -r '.data.result[0].value[1] // empty'; }
log()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '  ---- %s\n' "$*"; }
check(){ local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
wait_for() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do ((SECONDS >= end)) && return 1; sleep 2; done
}

hosts_on()     { [ "$(q "$1" 'count(count by (host) (node_uname_info))')" = "${2:-7}" ]; }
# seconds since the newest sample from <host> arrived at <db>
age_on()       { q "$1" "time() - timestamp(node_uname_info{host=\"$2\"})" | cut -d. -f1; }
fresh_on()     { local a; a=$(age_on "$1" "$2"); [ -n "$a" ] && [ "$a" -le 30 ]; }
service_http() { c -o /dev/null -w '%{http_code}' "$@"; }

sink_clear()   { c -X DELETE http://172.31.10.60:5001/ >/dev/null; }
# delivered notifications for <alertname> [host]
sink_count()   {
  c http://172.31.10.60:5001/ | jq --arg a "$1" --arg h "${2:-}" \
    '[.[] | select(.status == "firing") | .alerts[] | select(.labels.alertname == $a and ($h == "" or .labels.host == $h))] | length'
}
sink_has()     { [ "$(sink_count "$@")" -ge 1 ]; }
heartbeat()    { c http://172.31.10.61:8000/status | jq -r "$1"; }
hb_is()        { [ "$(heartbeat .status)" = "$1" ]; }

# Largest gap (s) between consecutive raw samples of a host's node_uname_info within the last <window>.
max_gap() {
  prom "$1" /api/v1/query --data-urlencode "query=node_uname_info{host=\"$2\"}[$3]" |
    jq '[.data.result[0].values // [] | map(.[0]) | . as $t | range(1; length) | $t[.] - $t[. - 1]] | max // 9999 | floor'
}
samples() {
  prom "$1" /api/v1/query --data-urlencode "query=count_over_time(node_uname_info{host=\"$2\"}[$3])" |
    jq -r '.data.result[0].value[1] // 0'
}

stop_host()  { docker compose stop $(docker compose config --services | grep "^$1-") "$1" >/dev/null 2>&1; }
start_host() { docker compose start "$1" >/dev/null 2>&1; docker compose start $(docker compose config --services | grep "^$1-") >/dev/null 2>&1; }

# ── 0. readiness ─────────────────────────────────────────────────────────────────────────────
log "0 · Stack ready"
check "all 7 hosts reporting to db1" wait_for 180 hosts_on db1
check "all 7 hosts reporting to db2" wait_for 60 hosts_on db2
check "heartbeat service receiving Watchdog pings" wait_for 60 hb_is up

# ── 1. both copies complete ──────────────────────────────────────────────────────────────────
log "1 · Every host's data lands on BOTH Prometheus instances"
for h in "${HOSTS[@]}"; do
  a1=$(age_on db1 "$h"); a2=$(age_on db2 "$h")
  ok=0; [ -n "$a1" ] && [ -n "$a2" ] && [ "$a1" -le 30 ] && [ "$a2" -le 30 ] && ok=1
  check "$h: fresh on db1 (${a1}s old) and db2 (${a2}s old)" [ $ok = 1 ]
done
check "host label comes from the machine's hostname (constants.hostname)" \
  [ "$(prom db1 /api/v1/label/host/values | jq -c '.data | sort')" = '["cpu1","cpu2","db1","db2","gpu1","prod3","prod4"]' ]
check "host-alive: db1 sees all 7 node-exporters" [ "$(q db1 'count(up{job="host-alive"} == 1)')" = 7 ]
check "host-alive keeps only 'up' (scraped metrics dropped, no duplicates of Alloy data)" \
  [ "$(q db1 'count({job="host-alive", __name__!~"up|scrape_.*"})')" = "" ]

# ── 2. security ──────────────────────────────────────────────────────────────────────────────
log "2 · TLS + basic auth"
for n in db1 db2; do
  check "$n: no credentials → 401" \
    [ "$(service_http --cacert /certs/ca.pem "https://$n.prometheus.amf/api/v1/query?query=up")" = 401 ]
  check "$n: wrong password → 401" \
    [ "$(service_http --cacert /certs/ca.pem -u grafana:wrong "https://$n.prometheus.amf/api/v1/query?query=up")" = 401 ]
  check "$n: remote write with wrong password → 401" \
    [ "$(service_http --cacert /certs/ca.pem -u alloyuser:wrong -X POST --data-binary x "https://$n.prometheus.amf/api/v1/write")" = 401 ]
  cx curl -sS -m 5 -o /dev/null "https://$n.prometheus.amf/-/healthy" >/dev/null 2>&1
  check "$n: certificate not trusted without the CA (curl exit $?)" [ $? -ne 0 ]
  ip=$([ $n = db1 ] && echo 172.31.10.20 || echo 172.31.10.21)
  check "$n: plain Prometheus port 9090 not reachable from the LAN" [ "$(service_http "http://$ip:9090/-/healthy")" = 000 ]
done
for u in prom-db1 prom-db2; do
  check "Grafana datasource $u healthy (TLS + auth from Grafana)" \
    [ "$(c -u admin:rehearsal "http://172.31.10.20:3000/api/datasources/uid/$u/health" | jq -r .status)" = OK ]
done

# ── 3. Watchdog / heartbeat ──────────────────────────────────────────────────────────────────
log "3 · Watchdog heartbeat"
check "last heartbeat $(heartbeat .last_ping_age)s ago (< 30s grace)" [ "$(heartbeat '.last_ping_age | floor')" -lt 30 ]
check "Watchdog is NOT sent to the team channel" [ "$(sink_count Watchdog)" = 0 ]

# ── 4. HostDown ──────────────────────────────────────────────────────────────────────────────
log "4 · A host dies (stop prod4 entirely)"
sink_clear
stop_host prod4
if wait_for 120 sink_has HostDown prod4; then
  sleep 20
  n=$(sink_count HostDown prod4)
  check "HostDown prod4 delivered exactly once (got $n)" [ "$n" = 1 ]
else
  fail "HostDown prod4 never delivered"
fi
check "no HostDown for any other host" [ "$(sink_count HostDown)" = "$(sink_count HostDown prod4)" ]
start_host prod4
ok=0; wait_for 120 fresh_on db1 prod4 && wait_for 60 fresh_on db2 prod4 && ok=1
check "prod4 reporting again on both" [ $ok = 1 ]

# ── 5. db2 dies ──────────────────────────────────────────────────────────────────────────────
log "5 · db2 dies (120s), then returns"
sink_clear
T0=$SECONDS
stop_host db2
if wait_for 120 sink_has HostDown db2; then
  pass "HostDown db2 alerted by db1 after ~$((SECONDS - T0))s"
else
  fail "HostDown db2 never delivered"
fi
check "db1 keeps receiving data from the other hosts" fresh_on db1 cpu1
remaining=$((120 - (SECONDS - T0))); [ "$remaining" -gt 0 ] && sleep "$remaining"
start_host db2
wait_for 120 fresh_on db2 cpu1
sleep 30   # let the backlog drain
g=$(max_gap db2 cpu1 5m)
check "db2's gap for cpu1 was back-filled by Alloy (largest gap ${g}s ≤ ${MAX_GAP}s)" [ "$g" -le $MAX_GAP ]

# ── 6. db1 dies — the main scenario ──────────────────────────────────────────────────────────
log "6 · db1 dies for ${OUTAGE}s (monitoring host + alerting), then returns"
sink_clear
T0=$SECONDS
stop_host db1
info "db1 stopped at $(date +%T)"
check "db2 keeps receiving data from all other hosts" wait_for 30 fresh_on db2 cpu1
if wait_for 90 sink_has HeartbeatMissing; then
  pass "heartbeat service paged 'monitoring down' after ~$((SECONDS - T0))s"
else
  fail "heartbeat service never paged"
fi
remaining=$((OUTAGE - (SECONDS - T0))); [ "$remaining" -gt 0 ] && { info "holding outage for ${remaining}s more"; sleep "$remaining"; }
check "'monitoring down' paged exactly once during the outage (got $(sink_count HeartbeatMissing))" [ "$(sink_count HeartbeatMissing)" = 1 ]
start_host db1
info "db1 started at $(date +%T)"
check "db1 Prometheus back with all hosts" wait_for 180 hosts_on db1
check "heartbeat recovered" wait_for 90 hb_is up
sleep 60   # let every Alloy drain its backlog to db1
WINDOW="$((OUTAGE / 60 + 5))m"
# db2 is left out: the window also covers test 5, when db2 itself was down and nobody collected its metrics
for h in cpu1 cpu2 gpu1 prod3 prod4; do
  g=$(max_gap db1 "$h" "$WINDOW"); s1=$(samples db1 "$h" "$WINDOW"); s2=$(samples db2 "$h" "$WINDOW")
  ok=0; [ "$g" -le $MAX_GAP ] && [ "$s1" -ge $((s2 * 95 / 100)) ] && ok=1
  check "$h: db1's gap back-filled (largest gap ${g}s; samples db1=$s1 vs db2=$s2)" [ $ok = 1 ]
done
g=$(max_gap db1 db1 "$WINDOW")
info "db1's own metrics: largest gap ${g}s on db1, $(max_gap db2 db1 "$WINDOW")s on db2 — expected: nobody collected them while db1 was down"
info "db1 Prometheus ingestion counters (late data accepted vs rejected):"
prom db1 /metrics | grep -E '^prometheus_tsdb_(head_out_of_order_samples_appended_total|out_of_order_samples_total|out_of_bound_samples_total|too_old_samples_total)' |
  sed 's/^/         /'

# ── summary ──────────────────────────────────────────────────────────────────────────────────
log "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
