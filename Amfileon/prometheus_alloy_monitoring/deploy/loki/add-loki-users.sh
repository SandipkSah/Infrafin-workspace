#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Adds the users "alloy" (pushes logs) and "grafana" (reads logs)
# to nginx-proxy's basic-auth file for https://db1.loki.amf. promtail's existing user stays.
#
#   scp deploy/secrets/loki-htpasswd db1:loki-htpasswd        # bcrypt hashes only, no passwords
#   scp deploy/loki/add-loki-users.sh db1:
#   ssh -t db1 'bash ~/add-loki-users.sh'
#
# nginx reads the file on every request: no reload, no restart, nothing else is touched.
# A copy of the original goes to /root/loki-config-backups/. Running it again changes nothing.
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

F=/srv/docker/proxy/htpasswd/db1.loki.amf
NEW=${1:-/home/ssa/loki-htpasswd}
[ -f "$F" ] && [ -f "$NEW" ] || { echo "need $F and $NEW" >&2; exit 1; }

BK=/root/loki-config-backups/htpasswd-db1.loki.amf.$(date +%F-%H%M%S)
mkdir -p /root/loki-config-backups && chmod 700 /root/loki-config-backups
cp -a "$F" "$BK"

added=0
# make sure the file ends with a newline before appending
[ -z "$(tail -c1 "$F")" ] || echo >> "$F"
while IFS= read -r line; do
  user=${line%%:*}
  case "$user" in alloy|grafana) ;; *) echo "skipping unexpected user '$user'" >&2; continue ;; esac
  if grep -q "^$user:" "$F"; then
    echo "    $user already present — kept"
  else
    printf '%s\n' "$line" >> "$F"; added=$((added+1)); echo "    $user added"
  fi
done < "$NEW"
rm -f "$NEW"

echo "==> users in $F now: $(cut -d: -f1 "$F" | tr '\n' ' ')"
[ "$added" = 0 ] && rm -f "$BK" || echo "    backup: $BK"
echo "Rollback: sudo cp $BK $F"
