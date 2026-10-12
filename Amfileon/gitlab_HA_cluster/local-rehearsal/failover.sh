#!/bin/bash
# Fail GitLab over to the given node. Manual trigger, scripted steps.
#   ./failover.sh db2           refuses if the other node is still running (or hung)
#   ./failover.sh db2 --force   operator has confirmed the other node is dead/fenced
set -euo pipefail
cd "$(dirname "$0")"

TARGET=${1:?usage: failover.sh db1|db2 [--force]}
FORCE=${2:-}
case "$TARGET" in
  db1) OTHER=db2 ;;
  db2) OTHER=db1 ;;
  *) echo "usage: failover.sh db1|db2"; exit 2 ;;
esac

# 1. The old node must be down (in production: unreachable / powered off).
#    A hung node (paused here) still counts as running: only --force overrides.
if [ "$FORCE" != --force ] && [ "$(docker inspect -f '{{.State.Running}}' "gitlab-$OTHER" 2>/dev/null)" = true ]; then
  echo "[failover] gitlab-$OTHER is still running or hung; stop it, or confirm it is dead and use --force. Refusing."
  exit 1
fi

# 2. Move the active flag; the start guard now only lets $TARGET start
docker compose exec -T etcd etcdctl put /amf/gitlab/active "$TARGET" >/dev/null
echo "[failover] etcd /amf/gitlab/active = $TARGET"

# 3. Start GitLab on the target node (restore restart policy in case it was disabled)
docker update --restart=always "gitlab-$TARGET" >/dev/null 2>&1 || true
docker compose up -d --no-deps "gitlab-$TARGET"

# 4. Move gitlab.local-test.amf / registry.local-test.amf (stand-in for floating IP / DNS)
docker network disconnect amf-front "gitlab-$OTHER"  2>/dev/null || true
docker network disconnect amf-front "gitlab-$TARGET" 2>/dev/null || true
docker network connect --alias gitlab.local-test.amf --alias registry.local-test.amf amf-front "gitlab-$TARGET"
echo "[failover] gitlab.local-test.amf / registry.local-test.amf now point at gitlab-$TARGET"

# 5. Wait until GitLab answers
echo -n "[failover] waiting for GitLab on $TARGET "
for _ in $(seq 1 90); do
  if docker exec "gitlab-$TARGET" curl -fsS -m 5 -H 'Host: gitlab.local-test.amf' http://localhost/-/readiness >/dev/null 2>&1; then
    echo " ready"
    exit 0
  fi
  echo -n "."
  sleep 10
done
echo " timed out"
exit 1
