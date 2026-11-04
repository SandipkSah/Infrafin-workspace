#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Switches on GitLab's own metrics ports inside gitlab-ee
# (Puma :8083, Workhorse :9229, Sidekiq :8082, gitlab-exporter :9168) — none is published on the host.
#
#   scp deploy/services/enable-gitlab-metrics.sh deploy/services/gitlab/gitlab.rb.snippet db1:
#   ssh -t db1 'bash ~/enable-gitlab-metrics.sh'
#
# Appends ~/gitlab.rb.snippet to /etc/gitlab/gitlab.rb (once — skipped if already there), after a
# copy to /etc/gitlab/gitlab.rb.bak-amf-monitoring, then `gitlab-ctl reconfigure`: Puma and Sidekiq
# restart (a few seconds of 502s); the container is not recreated, the image is not changed.
set -euo pipefail
SNIPPET=${1:-$HOME/gitlab.rb.snippet}
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$SNIPPET"
C=gitlab-ee
[ -f "$SNIPPET" ] || { echo "$SNIPPET missing" >&2; exit 1; }

if docker exec "$C" grep -q "Amfileon monitoring" /etc/gitlab/gitlab.rb; then
  echo "==> gitlab.rb already contains the monitoring lines — not appending again"
else
  docker exec "$C" cp -p /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.bak-amf-monitoring
  { echo; cat "$SNIPPET"; } | docker exec -i "$C" tee -a /etc/gitlab/gitlab.rb >/dev/null
  echo "==> appended the monitoring lines (backup: /etc/gitlab/gitlab.rb.bak-amf-monitoring)"
fi

echo "==> gitlab-ctl reconfigure (takes 1–3 min)"
docker exec "$C" gitlab-ctl reconfigure > /tmp/gitlab-reconfigure.log 2>&1 \
  || { echo "!! reconfigure failed — last lines:" >&2; tail -20 /tmp/gitlab-reconfigure.log >&2; exit 1; }
tail -2 /tmp/gitlab-reconfigure.log

echo "==> checking the metrics ports (inside the container; Puma can need ~2 min after a reconfigure)"
ok=0
for i in $(seq 1 30); do
  ok=0; missing=""
  for p in 8083/metrics 9229/metrics 8082/metrics 9168/sidekiq; do
    code=$(docker exec "$C" curl -s -o /dev/null -w '%{http_code}' "http://localhost:$p" || true)
    if [ "$code" = 200 ]; then ok=$((ok + 1)); else missing="$missing $p→$code"; fi
  done
  [ $ok = 4 ] && break
  echo "    $ok/4 answering, waiting for:$missing"
  sleep 5
done
if [ $ok = 4 ]; then
  for p in 8083/metrics 9229/metrics 8082/metrics 9168/sidekiq; do echo "    $p → 200"; done
  echo "==> done: all 4 metrics ports answer. Tell Claude to switch Alloy on."
else
  echo "!! only $ok of 4 ports answer after 2.5 min — paste this output to Claude" >&2
fi
echo "    rollback if ever needed: sudo docker exec $C cp -p /etc/gitlab/gitlab.rb.bak-amf-monitoring /etc/gitlab/gitlab.rb && sudo docker exec $C gitlab-ctl reconfigure"
