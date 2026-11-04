#!/usr/bin/env bash
# Runs ON a host, by a person (sudo). Final step of the rollout (README step 6): our services get the
# same ownership as the others, so ssa — and therefore Claude — can no longer edit them.
#   scp deploy/lockdown.sh <host>:   then   ssh -t <host> 'bash ~/lockdown.sh'
# Containers keep running; nothing is restarted. Later changes: stage + install-on-host.sh.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
for d in /srv/docker/prometheus /srv/docker/alloy /srv/docker/grafana-dashboards; do
  [ -d "$d" ] || continue
  chown -R root:root "$d"
  find "$d" -type d -exec chmod 755 {} +
  find "$d" -type f -exec chmod 644 {} +
  find "$d" -type f -name '*.env' -exec chmod 600 {} +
  [ ! -f "$d/.env" ] || chmod 600 "$d/.env"
  echo "locked: $d ($(stat -c '%U:%G %a' "$d"), .env $(stat -c %a "$d/.env" 2>/dev/null || echo -))"
done
