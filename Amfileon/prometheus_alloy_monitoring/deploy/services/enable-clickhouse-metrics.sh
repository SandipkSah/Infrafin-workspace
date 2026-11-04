#!/usr/bin/env bash
# Runs ON the server, by a person (sudo). Switches on the built-in Prometheus endpoint (:9363) of
# ONE ClickHouse server or keeper container. One container per run.
#
#   scp deploy/services/enable-clickhouse-metrics.sh db1:
#   ssh -t db1 'bash ~/enable-clickhouse-metrics.sh db1.staging.ch.amf'                 # server
#   ssh -t db1 'bash ~/enable-clickhouse-metrics.sh db1.staging.keeper.amf --restart'   # keeper
#
# What it changes: adds one <prometheus> block (port 9363, not published) to the config file the
# owner already mounts into the container — /srv/docker/<project>/config.xml for a server (mounted
# as config.d/config.xml), keeper.xml for a keeper. Nothing else in that file, no compose change.
# A copy of the original goes to /root/clickhouse-config-backups/ (not into /srv/docker, which is
# under version control). The rollback command is printed at the end.
#
# NO RESTART for servers: ClickHouse re-reads its config files every few seconds and opens the
# new port while running — running queries, inserts and merges are not interrupted (tested
# 2026-10-28 with 26.3: uptime kept counting, :9363 open within seconds). Keepers do not open the
# port on reload; they are restarted only when --restart is given (otherwise the port opens at
# their next restart, whenever that happens).
set -euo pipefail
C=${1:?usage: $0 <container> [--restart]}
RESTART=${2:-}
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

src() { docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$1\"}}{{.Source}}{{end}}{{end}}" "$C"; }
F=$(src /etc/clickhouse-server/config.d/config.xml); KIND=server
[ -n "$F" ] || { F=$(src /etc/clickhouse-keeper/keeper_config.xml); KIND=keeper; }
[ -n "$F" ] && [ -f "$F" ] || { echo "$C: no mounted config.d/config.xml or keeper_config.xml" >&2; exit 1; }
[ -n "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$C")" ] \
  || { echo "$C has no Docker network (host networking?) — not handled by this script" >&2; exit 1; }
echo "==> $C ($KIND): $F"

# insert the block before the root element's closing tag; refuse if it is already active or the
# result does not parse (comments, formatting and the rest of the file stay byte-for-byte)
NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
set +e
python3 - "$F" "$NEW" "$KIND" <<'PY'
import sys, xml.etree.ElementTree as ET
src, dst, kind = sys.argv[1:]
raw = open(src, "rb").read()
root = ET.fromstring(raw)
if root.find("prometheus") is not None:
    print("    already has an active <prometheus> block — nothing to change"); sys.exit(3)
if kind == "keeper" and root.find("listen_host") is None:
    print("    keeper config has no <listen_host>: :9363 would only listen on localhost — ask Claude"); sys.exit(4)
text = raw.decode()
end = text.rfind(f"</{root.tag}>")
block = """    <!-- Amfileon monitoring (Alloy): metrics endpoint, not published; read over the Docker network.
         Source: prometheus_alloy_monitoring/deploy/services/enable-clickhouse-metrics.sh -->
    <prometheus>
        <endpoint>/metrics</endpoint>
        <port>9363</port>
        <metrics>true</metrics>
        <events>true</events>
        <asynchronous_metrics>true</asynchronous_metrics>
        <errors>false</errors>   <!-- one series per error code; failed queries are counted in FailedQuery -->
    </prometheus>
"""
new = text[:end] + block + text[end:]
ET.fromstring(new.encode())
open(dst, "w").write(new)
PY
rc=$?
set -e
[ $rc = 0 ] || [ $rc = 3 ] || exit $rc

BACKUP="(none — the block was already there)"
if [ $rc = 0 ]; then
  BK=/root/clickhouse-config-backups/$C
  mkdir -p "$BK"; chmod 700 /root/clickhouse-config-backups
  BACKUP=$BK/$(basename "$F").$(date +%Y%m%d-%H%M%S)
  cp -p "$F" "$BACKUP"
  cat "$NEW" > "$F"            # in place: keeps owner, mode and inode of the bind-mounted file
  echo "    added <prometheus> (original saved as $BACKUP)"
fi

IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$C" | awk '{print $1}')
# count instead of grep -q: with pipefail, grep -q closing the pipe early makes wget (and the check) fail
answering() { local n; n=$(docker exec "$C" wget -qO- "http://$IP:9363/metrics" 2>/dev/null | grep -c '^ClickHouse' || true); [ "${n:-0}" -gt 0 ]; }
show() {
  docker exec "$C" wget -qO- "http://$IP:9363/metrics" | grep -E \
    '^ClickHouse(AsyncMetrics_(Uptime|ReplicasMaxAbsoluteDelay|MaxPartCountForPartition|KeeperIsLeader|KeeperZnodeCount|KeeperAvgLatency)|Metrics_(ReadonlyReplica|ZooKeeperSession|KeeperAliveConnections|KeeperOutstandingRequests)) ' \
    | sed 's/^/      /'
}
ROLLBACK="sudo cp -p $BACKUP $F"

echo "==> waiting for $C to pick up the config (no restart; up to 60 s)"
for i in $(seq 1 30); do
  if answering; then
    echo "    metrics answering on $IP:9363 after $((i * 2)) s — container NOT restarted"
    show
    echo "==> done. Rollback if ever needed: $ROLLBACK   (picked up again without restart)"
    exit 0
  fi
  sleep 2
done

if [ "$RESTART" != --restart ]; then
  echo "==> config is in place, but $C ($KIND) does not open the port without a restart."
  echo "    Nothing was restarted. The port opens at its next restart, or now with:"
  echo "      bash ~/enable-clickhouse-metrics.sh $C --restart"
  exit 0
fi

echo "==> restarting $C (--restart given)"
docker restart "$C" >/dev/null
for i in $(seq 1 90); do
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$C")
  if [ "$health" != starting ] && answering; then
    echo "    metrics answering on $IP:9363 after $((i * 2)) s; container health: $health"
    show
    echo "==> done. Rollback if ever needed: $ROLLBACK && sudo docker restart $C"
    exit 0
  fi
  sleep 2
done
echo "!! no metrics after 3 min (health: $health). Logs: sudo docker logs --tail 50 $C" >&2
echo "!! rollback: $ROLLBACK && sudo docker restart $C" >&2
exit 1
