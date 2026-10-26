#!/usr/bin/env bash
# Checks one host's Alloy from any machine on the VPN — no root, no docker.
#   ./verify-host.sh cpu2
# Queries both Prometheus instances (grafana user; password passed to curl, never printed).
set -uo pipefail
cd "$(dirname "$0")"

HOST=${1:?usage: $0 <host>}
case "$HOST" in
  db1) IP=10.10.10.20; JOBS="nodeexporter cadvisor nginx postgres-db1 postgres-db1-develop" ;;
  db2) IP=10.10.10.21; JOBS="nodeexporter cadvisor nginx scaphandre postgres-db2 postgres-db2-develop" ;;
  cpu1) IP=10.10.10.30; JOBS="nodeexporter cadvisor nginx" ;;
  cpu2) IP=10.10.10.31; JOBS="nodeexporter cadvisor scaphandre" ;;
  gpu1) IP=10.10.10.40; JOBS="nodeexporter cadvisor scaphandre nvidia_dcg_export" ;;
  prod3) IP=10.10.10.13; JOBS="nodeexporter cadvisor nginx scaphandre" ;;
  *) echo "unknown host: $HOST" >&2; exit 1 ;;
esac
CA=ca/amfileon-ca.pem
GRAFANA="grafana:$(sed -n 's/^GRAFANA_PROMETHEUS_PASSWORD=//p' secrets/grafana.env)"
PASS=0; FAIL=0
ok()   { echo "  PASS $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
# q <db1|db2> <promql> → first value
q() { curl -s -m 10 --cacert $CA -u "$GRAFANA" "https://$1.prometheus.amf/api/v1/query" --data-urlencode "query=$2" |
      sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'; }

echo "Verifying Alloy on $HOST ($IP)"
if curl -s -m 5 -o /dev/null "http://$IP:12345/-/ready"; then ok "Alloy answers on $IP:12345"; else bad "Alloy not reachable on $IP:12345 (host-alive / HostDown will fire)"; fi

for db in db1 db2; do
  for job in $JOBS; do
    up=$(q $db "max(up{host=\"$HOST\",job=\"$job\"})")
    age=$(q $db "time() - max(timestamp(up{host=\"$HOST\",job=\"$job\"}))" | cut -d. -f1)
    max_age=60; [ "$job" = scaphandre ] && max_age=150   # scraped every 60s (slow exporter)
    if [ "$up" = 1 ] && [ -n "$age" ] && [ "$age" -le $max_age ]; then ok "$db: $job up, last sample ${age}s ago"
    else bad "$db: $job (up=${up:-none}, last sample ${age:-never}s ago)"; fi
  done
done
hostalive=$(q db1 "up{job=\"host-alive\",host=\"$HOST\"}")
if [ "$hostalive" = 1 ]; then ok "db1 host-alive sees $HOST"; else bad "db1 host-alive: up=${hostalive:-none}"; fi

echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
