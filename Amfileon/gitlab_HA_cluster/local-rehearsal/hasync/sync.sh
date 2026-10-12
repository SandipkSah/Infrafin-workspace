#!/bin/sh
# File sync from the ACTIVE node to the other one (direction read from etcd).
# - every 2 s: drain the post-receive queue -> rsync just those repos (seconds of lag)
# - every SWEEP_INTERVAL s: full sweep of repos, uploads, shared files, registry, /etc/gitlab
# In production this runs on the active host and rsyncs over SSH; here both "servers'"
# volumes are mounted under /n/db1 and /n/db2.
set -u
ETCD=${HA_ETCD:-http://etcd:2379}
SWEEP=${SWEEP_INTERVAL:-300}
R="rsync -a --numeric-ids --mkpath"

b64() { printf %s "$1" | base64 | tr -d '\n'; }
get() { curl -fsS -m 5 -X POST "$ETCD/v3/kv/range" -d "{\"key\":\"$(b64 "$1")\"}" \
          | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' | base64 -d 2>/dev/null; }
put() { curl -fsS -m 5 -X POST "$ETCD/v3/kv/put" -d "{\"key\":\"$(b64 "$1")\",\"value\":\"$(b64 "$2")\"}" >/dev/null; }
log() { echo "[hasync $(date +%T)] $*"; }

sweep() {
  S=$1 D=$2
  [ -d "$S/data/git-data" ]           && $R --delete "$S/data/git-data/"           "$D/data/git-data/"
  [ -d "$S/data/gitlab-rails/uploads" ] && $R --delete "$S/data/gitlab-rails/uploads/" "$D/data/gitlab-rails/uploads/"
  [ -d "$S/data/gitlab-rails/shared" ] && $R --delete --exclude /registry/ \
                                          "$S/data/gitlab-rails/shared/"  "$D/data/gitlab-rails/shared/"
  # registry blobs are immutable: copy only, never delete (GC on the active side prunes)
  [ -d "$S/data/gitlab-rails/shared/registry" ] && $R "$S/data/gitlab-rails/shared/registry/" \
                                                      "$D/data/gitlab-rails/shared/registry/"
  [ -f "$S/data/.ssh/authorized_keys" ] && $R "$S/data/.ssh/" "$D/data/.ssh/"
  $R --delete "$S/config/" "$D/config/"
}

drain_queue() {
  S=$1 D=$2
  for f in "$S"/data/ha-sync-queue/*; do
    [ -f "$f" ] || continue
    rel=$(cat "$f")
    if [ "$rel" = ALL ] || [ -z "$rel" ]; then
      $R --delete "$S/data/git-data/" "$D/data/git-data/" && log "queue: full git-data sync"
    else
      $R --delete "$S/data/git-data/repositories/$rel/" "$D/data/git-data/repositories/$rel/" \
        && log "queue: synced repo $rel"
    fi
    rm -f "$f"
  done
}

last_sweep=0
last_hb=0
while :; do
  active=$(get /amf/gitlab/active)
  case "$active" in
    db1) S=/n/db1 D=/n/db2 ;;
    db2) S=/n/db2 D=/n/db1 ;;
    *)   log "active node unknown ('$active'), not syncing"; sleep 5; continue ;;
  esac
  drain_queue "$S" "$D"
  now=$(date +%s)
  # heartbeat: lets monitoring tell "sync job dead" from "nothing to sync"
  if [ $((now - last_hb)) -ge 10 ]; then put /amf/gitlab/sync_heartbeat "$now" && last_hb=$now; fi
  if [ $((now - last_sweep)) -ge "$SWEEP" ]; then
    if sweep "$S" "$D"; then
      last_sweep=$now
      put /amf/gitlab/last_full_sync "$now"
      log "full sweep $active -> $(basename "$D") done"
    else
      log "full sweep FAILED"
    fi
  fi
  sleep 2
done
