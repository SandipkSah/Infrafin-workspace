#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Fixes the crash loop of the Redis 8 container `redis`
# (/srv/docker/redis, port 36379; 2026-11-13):
#
#   "Module …//redisbloom.so initialization failed … Can't load module …: server aborting" — every minute
#
# Cause (reproduced with redis:8.10.3): the image's entrypoint adds --loadmodule for every bundled
# module (bloom, search, timeseries, json) at each start, and CONFIG REWRITE — done e.g. when the
# sentinels reconfigure the instance — writes the same modules as `loadmodule` lines into
# tmp-conf/redis.conf. The next start loads them twice; RedisBloom refuses → Redis aborts → Docker
# restarts it forever, and the sentinels on db1/prod3/prod4 try a failover every 20 s.
#
# Fix: a small entrypoint wrapper for the `redis` service only — before every start it deletes the
# `loadmodule` lines from redis.conf, then runs the image's normal entrypoint (which loads the
# modules once). Tested: 3× CONFIG REWRITE + restart → always "Ready", modules loaded once, file
# ownership (redis 999, 600) unchanged. The sentinel service is not touched.
#
#   ssh -t db1 'bash ~/fix-redis8-db1.sh'           # dry run: shows the change
#   ssh -t db1 'bash ~/fix-redis8-db1.sh --apply'   # backup, change, recreate `redis` only
set -euo pipefail
[ "$(id -u)" = 0 ] || [ -n "${NO_SUDO:-}" ] || exec sudo bash "$0" "$@"
DIR=${REDIS_DIR:-/srv/docker/redis}
F=$DIR/docker-compose.yaml
cd "$DIR"

ANCHOR='    command: redis-server /etc/redis/redis.conf'
if grep -q "^    entrypoint: \[\"sh\", \"-c\", \"sed -i '/^loadmodule /d'" "$F"; then
  echo "wrapper already in $F — nothing to change"
else
  n=$(grep -cxF "$ANCHOR" "$F" || true)
  [ "$n" = 1 ] || { echo "expected exactly one line '$ANCHOR' in $F, found $n — nothing changed" >&2; exit 1; }
  echo "==> $F: add before '$ANCHOR' (service redis only):"
  cat <<'EOF' | tee /tmp/redis8-wrapper.txt
    # 2026-11-13: the image adds --loadmodule for its bundled modules at every start, and CONFIG
    # REWRITE writes the same modules into redis.conf → loaded twice → "server aborting". Drop the
    # loadmodule lines before every start (prometheus_alloy_monitoring/deploy/services/fix-redis8-db1.sh)
    entrypoint: ["sh", "-c", "sed -i '/^loadmodule /d' /etc/redis/redis.conf; exec docker-entrypoint.sh \"$$@\"", "--"]
EOF
  if [ "${1:-}" != --apply ]; then echo "==> dry run — nothing changed (add --apply)"; rm -f /tmp/redis8-wrapper.txt; exit 0; fi
  BK=/root/redis8-backups/docker-compose.yaml.$(date +%F-%H%M%S)
  mkdir -p /root/redis8-backups && chmod 700 /root/redis8-backups && cp -a "$F" "$BK"
  TMP=$(mktemp)
  awk -v anchor="$ANCHOR" -v ins=/tmp/redis8-wrapper.txt '$0==anchor { while ((getline l < ins) > 0) print l } { print }' "$F" > "$TMP"
  cat "$TMP" > "$F"; rm -f "$TMP" /tmp/redis8-wrapper.txt     # keeps owner/permissions
  docker compose config -q || { cp -a "$BK" "$F"; echo "compose rejects the file — original restored" >&2; exit 1; }
  echo "    backup: $BK"
fi
[ "${1:-}" = --apply ] || { echo "==> dry run — nothing changed (add --apply)"; exit 0; }

echo "==> recreating only the redis service (the sentinel keeps running)"
docker compose up -d --no-deps redis
for i in $(seq 1 30); do docker logs --since 1m redis 2>&1 | grep -q "Ready to accept connections" && break; sleep 2; done
echo "==> redis:"; docker logs --since 1m redis 2>&1 | grep -E "Redis version|Module '|aborting|Ready to accept|MASTER|REPLICA|Fatal" | tail -10 | sed 's/^/    /'
sleep 30
echo "==> still running 30 s later: $(docker inspect -f '{{.State.Status}}, restarts {{.RestartCount}}' redis)"
echo "==> sentinel (should stop trying failovers):"; docker logs --since 1m redis-sentinel 2>&1 | grep -E "\-sdown|\-odown|\+sdown|\+odown|try-failover|failover-abort" | tail -5 | sed 's/^/    /'
[ -n "${BK:-}" ] && echo "Rollback: sudo cp $BK $F && cd $DIR && sudo docker compose up -d --no-deps redis"
