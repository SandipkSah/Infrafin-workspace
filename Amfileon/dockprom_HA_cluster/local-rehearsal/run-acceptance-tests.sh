#!/usr/bin/env bash
# Acceptance tests for the dockprom HA design — tests 1–10 in ../README.md.
#
# Usage (from this directory):
#   docker compose up -d --build
#   ./run-acceptance-tests.sh
#   docker compose down -v          # tear down afterwards
#
# The tests stop and start containers to simulate failures, and leave the stack running and
# healthy at the end. Takes ~5 minutes, mostly waiting for alert `for:` durations.
set -uo pipefail
cd "$(dirname "$0")"

A=172.31.10.20
B=172.31.10.21
VIP=172.31.10.100
SINK=172.31.10.40:5001
EXPORTERS=5            # node-exporters configured in prometheus.yml
PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────────────────────
# curl from the client container (the Mac cannot reach the lan network directly).
# </dev/null stops `docker compose exec` from swallowing the script's stdin.
c()      { docker compose exec -T client curl -sS -m 5 "$@" </dev/null; }
gf()     { c -u admin:rehearsal "http://$1:3000$2" "${@:3}"; }
log()    { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check()  { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

# wait_for <timeout-seconds> <command...> — retry every second until the command succeeds
wait_for() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    ((SECONDS >= end)) && return 1
    sleep 1
  done
}

# Instant query against a node's Thanos Query; prints the first value.  q <ip> <promql> [curl args]
q() { c -G "http://$1:10904/api/v1/query" --data-urlencode "query=$2" "${@:3}" | jq -r '.data.result[0].value[1] // empty'; }
q_is() { [ "$(q "$@" | head -1)" = "$EXPECT" ]; }

vip_holder() {
  local n
  for n in node-a node-b; do
    docker compose exec -T "$n-keepalived" ip -4 -o addr show eth0 </dev/null 2>/dev/null | grep -q "$VIP/" && echo "$n"
  done
}
vip_on()        { [ "$(vip_holder)" = "$1" ]; }
vip_on_one()    { [ "$(vip_holder | wc -l | tr -d ' ')" = 1 ]; }
grafana_up()    { [ "$(c -o /dev/null -w '%{http_code}' "http://$1:3000/api/health")" = 200 ]; }
stores_healthy(){ [ "$(c "http://$1:10904/api/v1/stores" | jq '[.data.sidecar[]? | select(.lastError == null)] | length')" = 2 ]; }
am_peers()      { [ "$(c "http://$1:9093/api/v2/status" | jq '.cluster.peers | length')" = 2 ]; }

# Number of delivered *firing* notifications for one alert.  sink_count <alertname> <instance>
sink_count() {
  c "http://$SINK/" | jq --arg a "$1" --arg i "$2" \
    '[.[] | select(.status == "firing") | .alerts[] | select(.labels.alertname == $a and .labels.instance == $i)] | length'
}
sink_at_least_one() { [ "$(sink_count "$@")" -ge 1 ]; }
sink_clear()        { c -X DELETE "http://$SINK/" >/dev/null; }

# Largest gap (seconds) between consecutive raw samples of a series over the last <window>.
#   max_gap <ip> <selector> <window> <dedup:true|false> [replica]
max_gap() {
  c -G "http://$1:10904/api/v1/query" --data-urlencode "query=$2[$3]" --data-urlencode "dedup=$4" |
    jq --arg r "${5:-}" '[.data.result[] | select($r == "" or .metric.replica == $r) | .values | map(.[0])
                          | [range(1; length) as $i | .[$i] - .[$i - 1]] | max] | max // 9999 | floor'
}

node_a_services() { docker compose config --services | grep '^node-a-'; }

# ── 0. readiness ─────────────────────────────────────────────────────────────────────────────
log "0 · Waiting for the stack to be ready"
EXPECT=$EXPORTERS
wait_for 120 q_is $A "count(up{job=\"nodeexporter\"} == 1)" &&
  wait_for 60 q_is $B "count(up{job=\"nodeexporter\"} == 1)" &&
  wait_for 60 stores_healthy $A && wait_for 60 stores_healthy $B &&
  wait_for 60 am_peers $A && wait_for 60 grafana_up $A && wait_for 60 grafana_up $B &&
  wait_for 30 vip_on_one
check "stack ready (all exporters up, both sidecars, AM cluster, both Grafanas, VIP on one node)" [ $? = 0 ]
echo "  VIP currently on: $(vip_holder)"

# ── 1. steady state ──────────────────────────────────────────────────────────────────────────
log "1 · Steady state — two copies, de-duplicated into one"
check "dedup on  → $EXPORTERS node-exporter series (node-a query)" [ "$(q $A 'count(up{job="nodeexporter"})')" = $EXPORTERS ]
check "dedup on  → $EXPORTERS node-exporter series (node-b query)" [ "$(q $B 'count(up{job="nodeexporter"})')" = $EXPORTERS ]
check "dedup off → $((EXPORTERS * 2)) series (proves both replicas hold a full copy)" \
  [ "$(q $A 'count(up{job="nodeexporter"})' --data-urlencode dedup=false)" = $((EXPORTERS * 2)) ]

# ── 2. lose one Prometheus ───────────────────────────────────────────────────────────────────
log "2 · Lose one Prometheus (stop node-a-prometheus)"
docker compose stop node-a-prometheus >/dev/null 2>&1
T_STOP=$SECONDS
sleep 5
check "node-a Thanos Query still answers ($EXPORTERS targets up)" [ "$(q $A 'count(up{job="nodeexporter"} == 1)')" = $EXPORTERS ]
check "node-b Thanos Query still answers ($EXPORTERS targets up)" [ "$(q $B 'count(up{job="nodeexporter"} == 1)')" = $EXPORTERS ]
for ip in $A $B; do
  v=$(gf $ip /api/datasources/proxy/uid/thanos/api/v1/query -G --data-urlencode 'query=count(up{job="nodeexporter"} == 1)' |
      jq -r '.data.result[0].value[1] // empty')
  check "Grafana on $ip answers through its datasource ($v targets)" [ "$v" = $EXPORTERS ]
done

# ── 3. gap fill ──────────────────────────────────────────────────────────────────────────────
log "3 · Gap fill — keep node-a-prometheus down ~45s, then restart"
remaining=$((45 - (SECONDS - T_STOP))); [ "$remaining" -gt 0 ] && sleep "$remaining"
docker compose start node-a-prometheus >/dev/null 2>&1
wait_for 60 stores_healthy $A
sleep 20   # let node-a scrape again so its gap is in the middle of the window
SEL='up{job="nodeexporter",instance="172.31.10.13:9100"}'
GAP_A=$(max_gap $A "$SEL" 2m false node-a)
GAP_DEDUP=$(max_gap $A "$SEL" 2m true)
echo "  largest gap: node-a replica alone = ${GAP_A}s, de-duplicated view = ${GAP_DEDUP}s"
check "node-a's own copy has the outage gap (≥ 30s)" [ "$GAP_A" -ge 30 ]
check "de-duplicated view has no gap (≤ 15s, i.e. at most a couple of 5s scrapes)" [ "$GAP_DEDUP" -le 15 ]

# ── 4. alert de-duplication ──────────────────────────────────────────────────────────────────
log "4 · Alert de-duplication — 2 Prometheus × 2 Alertmanager → 1 notification"
sink_clear
docker compose stop target-3-nodeexporter >/dev/null 2>&1
if wait_for 120 sink_at_least_one monitor_service_down 172.31.10.31:9100; then
  sleep 30   # longer than Alertmanager's peer timeout, so a duplicate would have arrived by now
  n=$(sink_count monitor_service_down 172.31.10.31:9100)
  check "monitor_service_down for target-3 delivered exactly once (got $n)" [ "$n" = 1 ]
else
  fail "monitor_service_down for target-3 never delivered"
fi
docker compose start target-3-nodeexporter >/dev/null 2>&1

# ── 6. silence propagation (runs before 5, which takes node-a away) ─────────────────────────
log "6 · Silence created on Alertmanager A appears on Alertmanager B"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
later=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
SID=$(c -X POST -H 'Content-Type: application/json' "http://$A:9093/api/v2/silences" -d \
  "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"rehearsal_test\",\"isRegex\":false,\"isEqual\":true}],
    \"startsAt\":\"$now\",\"endsAt\":\"$later\",\"createdBy\":\"acceptance-test\",\"comment\":\"test 6\"}" | jq -r .silenceID)
silence_on_b() { [ "$(c "http://$B:9093/api/v2/silence/$SID" | jq -r .status.state)" = active ]; }
check "silence $SID visible and active on node-b" wait_for 15 silence_on_b
c -X DELETE "http://$A:9093/api/v2/silence/$SID" >/dev/null

# ── 5. lose a whole node ─────────────────────────────────────────────────────────────────────
log "5 · Lose a whole node (stop every node-a container)"
sink_clear
docker compose stop $(node_a_services) node-a >/dev/null 2>&1
check "VIP moved to / stayed on node-b" wait_for 15 vip_on node-b
check "Grafana answers on the VIP" [ "$(c -o /dev/null -w '%{http_code}' "http://$VIP:3000/api/health")" = 200 ]
EXPECT=$((EXPORTERS - 1))
check "node-b Thanos Query answers ($((EXPORTERS - 1)) of $EXPORTERS exporters up)" \
  wait_for 30 q_is $B 'count(up{job="nodeexporter"} == 1)'
if wait_for 120 sink_at_least_one monitor_service_down 172.31.10.20:9100; then
  sleep 30
  n=$(sink_count monitor_service_down 172.31.10.20:9100)
  check "node-a's loss alerted by node-b, exactly once (got $n)" [ "$n" = 1 ]
else
  fail "node-a's loss was never alerted"
fi

# ── 7. node rejoin ───────────────────────────────────────────────────────────────────────────
log "7 · Node rejoin (start node-a again)"
docker compose start node-a >/dev/null 2>&1
docker compose start $(node_a_services) >/dev/null 2>&1
check "node-b Alertmanager sees 2 cluster peers again" wait_for 60 am_peers $B
t0=$SECONDS
if wait_for 180 stores_healthy $B; then
  pass "node-b Thanos Query sees both sidecars again (after $((SECONDS - t0))s — gRPC reconnect backoff)"
else
  fail "node-b Thanos Query did not see node-a's sidecar within 180s"
fi
check "node-a Thanos Query sees both sidecars" wait_for 60 stores_healthy $A
EXPECT=$EXPORTERS
check "all $EXPORTERS exporters up again" wait_for 60 q_is $B 'count(up{job="nodeexporter"} == 1)'
check "node-a Grafana healthy again" wait_for 60 grafana_up $A

# ── 8. Grafana VIP failover ──────────────────────────────────────────────────────────────────
log "8 · Grafana VIP failover (stop Grafana on whichever node holds the VIP)"
wait_for 30 vip_on_one
HOLDER=$(vip_holder)
OTHER=$([ "$HOLDER" = node-a ] && echo node-b || echo node-a)
echo "  VIP on $HOLDER → stopping $HOLDER-grafana"
docker compose stop "$HOLDER-grafana" >/dev/null 2>&1
t0=$SECONDS
if wait_for 20 vip_on "$OTHER"; then
  pass "VIP moved to $OTHER in $((SECONDS - t0))s"
else
  fail "VIP did not move to $OTHER within 20s"
fi
check "user can log in via the VIP" \
  [ "$(c -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "http://$VIP:3000/login" -d '{"user":"admin","password":"rehearsal"}')" = 200 ]
nd=$(gf $VIP '/api/search?type=dash-db' | jq length)
check "dashboards available via the VIP ($nd)" [ "${nd:-0}" -ge 1 ]

# ── 9. no flap-back ──────────────────────────────────────────────────────────────────────────
log "9 · No flap-back ($HOLDER-grafana comes back)"
docker compose start "$HOLDER-grafana" >/dev/null 2>&1
HOLDER_IP=$([ "$HOLDER" = node-a ] && echo $A || echo $B)
wait_for 60 grafana_up "$HOLDER_IP"
sleep 10   # > keepalived rise (2 × 2s) + election time
check "VIP stays on $OTHER after $HOLDER recovers" vip_on "$OTHER"

# ── 10. no drift ─────────────────────────────────────────────────────────────────────────────
log "10 · No drift between the two Grafanas"
DASH_A=$(gf $A '/api/search?type=dash-db' | jq -c '[.[] | {uid, title}] | sort_by(.uid)')
DASH_B=$(gf $B '/api/search?type=dash-db' | jq -c '[.[] | {uid, title}] | sort_by(.uid)')
check "identical dashboard list on both nodes ($(jq length <<<"$DASH_A") dashboards)" [ "$DASH_A" = "$DASH_B" -a "$DASH_A" != "[]" ]
DS_A=$(gf $A /api/datasources | jq -c '[.[] | {uid, name, type, url}] | sort_by(.uid)')
DS_B=$(gf $B /api/datasources | jq -c '[.[] | {uid, name, type, url}] | sort_by(.uid)')
check "identical datasources on both nodes ($DS_A)" [ "$DS_A" = "$DS_B" ]
UID1=$(jq -r '.[0].uid' <<<"$DASH_A")
BODY=$(gf $A "/api/dashboards/uid/$UID1" | jq -c '{dashboard: .dashboard, overwrite: true}')
RESP=$(gf $A /api/dashboards/db -X POST -H 'Content-Type: application/json' -d "$BODY" -w '\n%{http_code}')
CODE=$(tail -1 <<<"$RESP")
check "saving a provisioned dashboard through the API is rejected (HTTP $CODE: $(head -1 <<<"$RESP" | jq -r .message 2>/dev/null))" \
  [ "$CODE" -ge 400 ]

# ── summary ──────────────────────────────────────────────────────────────────────────────────
log "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
