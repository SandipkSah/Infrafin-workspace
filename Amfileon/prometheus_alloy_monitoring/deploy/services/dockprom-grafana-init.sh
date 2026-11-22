#!/usr/bin/env bash
# Runs ON a host, by a person (sudo). Adds `init: true` to dockprom's grafana service, so the
# healthcheck's `wget https://…` helper processes (ssl_client) are reaped instead of piling up as
# zombies under Grafana (PID 1 in the container; cpu1: ~246k since May, one per minute).
#
#   scp deploy/services/dockprom-grafana-init.sh cpu1:
#   ssh -t cpu1 'bash ~/dockprom-grafana-init.sh'
#
# Changes ONE line in /srv/docker/dockprom/docker-compose.override.yaml (`    init: true` right
# under `  grafana:`) and recreates ONLY the grafana container (--no-deps). Users, dashboards and
# settings live in the named volume grafana_data and stay; Grafana is down ~15 s. The zombies
# disappear with the old container. Backup → /root/dockprom-backups/. Nothing is printed from the
# compose files (they hold a password). Running it again changes nothing.
set -euo pipefail
[ "$(id -u)" = 0 ] || [ -n "${NO_SUDO:-}" ] || exec sudo bash "$0" "$@"   # NO_SUDO: local rehearsal only

DIR=${DOCKPROM_DIR:-/srv/docker/dockprom}
F=$DIR/docker-compose.override.yaml
C=${GRAFANA_CONTAINER:-grafana}
cd "$DIR"
[ -f "$F" ] || { echo "no $F" >&2; exit 1; }

zombies() { docker top "$C" -o pid,stat 2>/dev/null | awk 'NR>1 && $2 ~ /^Z/' | wc -l | tr -d ' '; }
init_on() { docker compose config --format json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["services"]["grafana"].get("init", False))'; }

echo "==> before: $(zombies) zombie processes under $C; init in compose: $(init_on)"
if [ "$(init_on)" = True ]; then
  echo "init already set in the compose files — nothing changed"
else
  BK=/root/dockprom-backups/docker-compose.override.yaml.$(date +%F-%H%M%S)
  mkdir -p /root/dockprom-backups && chmod 700 /root/dockprom-backups && cp -a "$F" "$BK"
  NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT
  python3 - "$F" "$NEW" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
idx = [i for i, l in enumerate(lines) if l.rstrip() == "  grafana:"]
if len(idx) != 1:
    sys.exit(f"expected exactly one '  grafana:' line, found {len(idx)} — nothing changed")
lines.insert(idx[0] + 1, "    init: true            # reap healthcheck child processes (no zombies) — dockprom-grafana-init.sh")
open(dst, "w").write("\n".join(lines))
PY
  cat "$NEW" > "$F"                       # keeps owner and mode of the original
  if [ "$(init_on)" != True ]; then
    cp -a "$BK" "$F"; echo "compose did not pick up init: true — restored the original, nothing else changed" >&2; exit 1
  fi
  echo "==> $F: added 'init: true' under grafana (backup $BK)"
fi

if [ "$(docker inspect -f '{{.HostConfig.Init}}' "$C" 2>/dev/null)" = true ]; then
  echo "==> container $C already runs with init"
else
  echo "==> recreating only $C (data stays in the grafana_data volume)"
  docker compose up -d --no-deps grafana
fi
for i in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ] && break; sleep 2; done
echo "==> after: running=$(docker inspect -f '{{.State.Running}}' "$C"), init=$(docker inspect -f '{{.HostConfig.Init}}' "$C"), PID 1 in the container: $(docker top "$C" -o pid,comm 2>/dev/null | awk 'NR==2{print $2}'), zombies under it: $(zombies)"
echo "Check again in a few minutes — the zombie count must stay 0:"
echo "  sudo docker top $C -o pid,stat,comm | grep -c ' Z'"
[ -n "${BK:-}" ] && echo "Rollback: sudo cp $BK $F && cd $DIR && sudo docker compose up -d --no-deps grafana"
