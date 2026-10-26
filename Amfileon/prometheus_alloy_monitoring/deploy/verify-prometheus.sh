#!/usr/bin/env bash
# Checks a deployed Prometheus from any machine on the VPN — no root, no docker.
#   ./verify-prometheus.sh db2        (or db1)
# Needs deploy/secrets/*.env from gen-secrets.sh. Passwords are passed to curl, never printed.
set -uo pipefail
cd "$(dirname "$0")"

HOST=${1:?usage: $0 db1|db2}
URL="https://$HOST.prometheus.amf"
CA=ca/amfileon-ca.pem
GRAFANA="grafana:$(sed -n 's/^GRAFANA_PROMETHEUS_PASSWORD=//p' secrets/grafana.env)"
ALLOY="alloyuser:$(sed -n 's/^ALLOY_PASSWORD=//p' secrets/alloy.env)"
PASS=0; FAIL=0
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
check() { local d=$1 want=$2 got=$3; if [ "$got" = "$want" ]; then echo "  PASS $d"; PASS=$((PASS+1)); else echo "  FAIL $d (expected $want, got $got)"; FAIL=$((FAIL+1)); fi; }

echo "Verifying $URL"
check "DNS resolves"                        yes "$( (dscacheutil -q host -a name "$HOST.prometheus.amf" 2>/dev/null || getent hosts "$HOST.prometheus.amf") | grep -q . && echo yes || echo no)"
check "TLS certificate trusted via Amfileon CA"     0 "$(curl -s -o /dev/null -m 10 --cacert $CA "$URL/" ; echo $?)"
check "no credentials → 401"                401 "$(code --cacert $CA "$URL/-/healthy")"
check "wrong password → 401"                401 "$(code --cacert $CA -u grafana:wrong "$URL/-/healthy")"
check "grafana user → healthy (200)"        200 "$(code --cacert $CA -u "$GRAFANA" "$URL/-/healthy")"
check "grafana user can query (200)"        200 "$(code --cacert $CA -u "$GRAFANA" "$URL/api/v1/query?query=vector(1)")"
# An empty body is rejected as a bad request (400) — which proves the receiver is enabled
# (404 = flag missing) and the alloyuser password is accepted (401 = wrong).
check "remote-write receiver on, alloyuser accepted (400 for empty body)" \
                                            400 "$(code --cacert $CA -u "$ALLOY" -X POST -H 'Content-Type: application/x-protobuf' --data-binary '' "$URL/api/v1/write")"
# least privilege (nginx vhost.d rule + no lifecycle endpoints)
check "grafana user cannot push (403)"      403 "$(code --cacert $CA -u "$GRAFANA" -X POST --data-binary '' "$URL/api/v1/write")"
check "alloyuser cannot read (403)"         403 "$(code --cacert $CA -u "$ALLOY" "$URL/api/v1/query?query=up")"
# GET only: Prometheus acts on lifecycle/admin endpoints only for POST/PUT, so these probes can
# never shut down or reload a live Prometheus — nginx must still answer 403 for the path itself.
check "/-/quit blocked (403)"               403 "$(code --cacert $CA -u "$GRAFANA" "$URL/-/quit")"
check "/-/reload blocked (403)"             403 "$(code --cacert $CA -u "$GRAFANA" "$URL/-/reload")"
check "admin API blocked (403)"             403 "$(code --cacert $CA -u "$GRAFANA" "$URL/api/v1/admin/tsdb/snapshot")"
# openssl exits non-zero when the handshake is refused (= the good case), so capture first:
# with pipefail a direct pipe into grep would report the refusal as a failure.
tls11=$(echo | openssl s_client -connect "$HOST.prometheus.amf:443" -servername "$HOST.prometheus.amf" -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' 2>&1 || true)
check "TLS 1.1 refused by the server"       refused "$(grep -q 'alert protocol version' <<<"$tls11" && echo refused || echo accepted)"
oo=$(curl -s -m 10 --cacert $CA -u "$GRAFANA" "$URL/api/v1/status/config" | grep -c 'out_of_order_time_window: 1d')
check "out_of_order_time_window = 24h active" 1 "$oo"

echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
