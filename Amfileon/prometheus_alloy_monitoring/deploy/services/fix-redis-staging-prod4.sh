#!/usr/bin/env bash
# Runs ON prod4, by a person (sudo). Fixes the crash loop of redis-staging-prod4 (2026-11-13):
#
#   "Can't handle RDB format version 12 … Fatal error loading the DB. Exiting." — ~1,450×/day
#
# The staging master (db2) and the other replica (db1) run redis/redis-stack-server:7.4.0-v8
# (Redis 7.4 → RDB format 12). prod4 still runs 7.2.0-v15 (reads up to format 11), so every start
# fails on the snapshot it received from the 7.4 master. Fix: the same image as db1/db2 for both
# services of this compose file (redis + its sentinel share one image template). The data in ./data
# stays; 7.4 reads it, and the sentinels make it a replica of db2 again.
#
#   ssh -t prod4 'bash ~/fix-redis-staging-prod4.sh'           # dry run: shows the change
#   ssh -t prod4 'bash ~/fix-redis-staging-prod4.sh --apply'   # backup, change, pull, recreate
set -euo pipefail
[ "$(id -u)" = 0 ] || [ -n "${NO_SUDO:-}" ] || exec sudo bash "$0" "$@"
DIR=${REDIS_DIR:-/srv/docker/redis-staging}
F=$DIR/docker-compose.yaml
OLD='redis/redis-stack-server:7.2.0-v15'
NEW='redis/redis-stack-server:7.4.0-v8'
cd "$DIR"

line=$(grep -nE "^  image: $OLD\$" "$F" | cut -d: -f1 || true)
if [ -z "$line" ]; then
  if grep -qE "^  image: $NEW( |$)" "$F"; then echo "already on $NEW — nothing to change"; else
    echo "expected '  image: $OLD' in $F — not found, nothing changed" >&2; exit 1; fi
else
  echo "==> $F line $line:  $OLD  →  $NEW   (template used by redis + sentinel)"
  if [ "${1:-}" != --apply ]; then echo "==> dry run — nothing changed (add --apply)"; exit 0; fi
  BK=/root/redis-staging-backups/docker-compose.yaml.$(date +%F-%H%M%S)
  mkdir -p /root/redis-staging-backups && chmod 700 /root/redis-staging-backups && cp -a "$F" "$BK"
  TMP=$(mktemp); sed "${line}s|^  image: $OLD\$|  image: $NEW   # was $OLD until 2026-11-13 (could not read RDB v12 from the 7.4 master)|" "$F" > "$TMP"
  cat "$TMP" > "$F"; rm -f "$TMP"                    # keeps owner/permissions
  docker compose config -q || { cp -a "$BK" "$F"; echo "compose rejects the file — original restored" >&2; exit 1; }
  echo "    backup: $BK"
fi
[ "${1:-}" = --apply ] || { echo "==> dry run — nothing changed (add --apply)"; exit 0; }

echo "==> pulling $NEW"; docker compose pull -q
echo "==> recreating redis-staging-prod4 + redis-sentinel-staging"; docker compose up -d
echo "==> waiting for Redis to come up (no restart loop)"
for i in $(seq 1 30); do
  st=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' redis-staging-prod4 2>/dev/null || echo "missing")
  docker logs --since 2m redis-staging-prod4 2>&1 | grep -q "Ready to accept connections" && break; sleep 2
done
echo "    state: $st"
docker logs --since 2m redis-staging-prod4 2>&1 | grep -E "Redis version|RDB|Ready to accept|MASTER|REPLICA|Fatal|Exiting|replicaof|Connecting to" | tail -12 | sed 's/^/    /'
echo "==> sentinel:"; docker logs --since 2m redis-sentinel-staging 2>&1 | grep -E "\+slave|\+convert-to-slave|\+sdown|-sdown|Sentinel ID|monitor" | tail -6 | sed 's/^/    /'
[ -n "${BK:-}" ] && echo "Rollback: sudo cp $BK $F && cd $DIR && sudo docker compose up -d"
