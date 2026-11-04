#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Puts authentik's client ID and secret for Grafana into
# /srv/docker/grafana-dashboards/.env and switches SSO on. Asks for both (the secret is not shown
# while typing) and never prints them.
#
#   scp deploy/db1/grafana/fill-grafana-oauth.sh db1:   then   ssh -t db1 'bash ~/fill-grafana-oauth.sh'
#
# Afterwards: ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'
# Switch SSO off again: bash ~/fill-grafana-oauth.sh --off   (then the install command again)
set -euo pipefail
DST=/srv/docker/grafana-dashboards/.env
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

umask 077
NEW=$(mktemp)
trap 'rm -f "$NEW"' EXIT
grep -v '^GRAFANA_OAUTH_' "$DST" > "$NEW" || true

if [ "${1:-}" = --off ]; then
  echo "GRAFANA_OAUTH_ENABLED=false" >> "$NEW"
else
  read -r -p "authentik Client ID: " id
  read -r -s -p "authentik Client Secret (not shown): " secret; echo
  [ -n "$id" ] && [ -n "$secret" ] || { echo "both are needed — nothing changed" >&2; exit 1; }
  case "$id$secret" in *"'"*) echo "contains a single quote — nothing changed" >&2; exit 1 ;; esac
  printf "GRAFANA_OAUTH_ENABLED=true\nGRAFANA_OAUTH_CLIENT_ID='%s'\nGRAFANA_OAUTH_CLIENT_SECRET='%s'\n" "$id" "$secret" >> "$NEW"
fi
cat "$NEW" > "$DST"            # in place: keeps root:root 600
echo "==> $DST: $(grep -o '^GRAFANA_OAUTH_[A-Z_]*' "$DST" | tr '\n' ' ')"
echo "    next: ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'"
