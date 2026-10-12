#!/bin/bash
# Start guard (container entrypoint): only start GitLab if etcd names this node as active.
# Prevents split-brain when a failed node comes back while the other one is serving.
set -u
NODE=${HA_NODE:?HA_NODE not set}
ETCD=${HA_ETCD:-http://etcd:2379}
KEY_B64=$(printf %s /amf/gitlab/active | base64)

active_node() {
  curl -fsS -m 5 -X POST "$ETCD/v3/kv/range" -d "{\"key\":\"$KEY_B64\"}" \
    | sed -n 's/.*"value":"\([^"]*\)".*/\1/p' | base64 -d 2>/dev/null
}

active=$(active_node)
if [ "$active" != "$NODE" ]; then
  echo "[ha-guard] REFUSING to start GitLab on $NODE: active node is '${active:-<etcd unreachable/unset>}'"
  sleep 30   # slow down the restart loop
  exit 1
fi
echo "[ha-guard] $NODE is the active node, starting GitLab"

# Global post-receive hook + sync queue (drained by hasync)
mkdir -p /var/opt/gitlab/gitaly/custom_hooks/post-receive.d /var/opt/gitlab/ha-sync-queue
install -m 0755 /ha/post-receive /var/opt/gitlab/gitaly/custom_hooks/post-receive.d/ha-sync
chown git:git /var/opt/gitlab/ha-sync-queue

# Self-fence: if the active flag moves to another node while we run, stop.
(
  while sleep 15; do
    a=$(active_node) || continue
    if [ -n "$a" ] && [ "$a" != "$NODE" ]; then
      echo "[ha-guard] active node changed to '$a', stopping GitLab on $NODE"
      gitlab-ctl stop
      kill -TERM 1
    fi
  done
) &

exec /assets/init-container
