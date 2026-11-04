#!/usr/bin/env bash
# Runs ON db1, by a person. Gives Grafana (https://grafana.amf) the same mail account Alertmanager
# uses, so it can send invite and password-reset emails. Copies SMTP_SMARTHOST, SMTP_FROM,
# SMTP_USERNAME and SMTP_PASSWORD from /srv/docker/prometheus/.env into
# /srv/docker/grafana-dashboards/.env as GRAFANA_SMTP_* — on the server, values are NEVER printed.
#
#   scp deploy/db1/grafana/fill-grafana-smtp.sh db1:   then   ssh -t db1 'bash ~/fill-grafana-smtp.sh'
#
# Afterwards: ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'
set -euo pipefail
SRC=/srv/docker/prometheus/.env
DST=/srv/docker/grafana-dashboards/.env
# root only needed after the final lockdown (then both files are root:root 600)
{ [ -r "$SRC" ] && [ -w "$DST" ]; } || [ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

for v in SMTP_SMARTHOST SMTP_FROM SMTP_USERNAME SMTP_PASSWORD; do
  grep -q "^$v=." "$SRC" || { echo "$v is missing or empty in $SRC — nothing changed" >&2; exit 1; }
done

umask 077
NEW=$(mktemp)
trap 'rm -f "$NEW"' EXIT
grep -v '^GRAFANA_SMTP_' "$DST" > "$NEW" || true          # replace earlier copies
sed -n -e 's/^SMTP_SMARTHOST=/GRAFANA_SMTP_HOST=/p' \
       -e 's/^SMTP_FROM=/GRAFANA_SMTP_FROM=/p' \
       -e 's/^SMTP_USERNAME=/GRAFANA_SMTP_USER=/p' \
       -e 's/^SMTP_PASSWORD=/GRAFANA_SMTP_PASSWORD=/p' "$SRC" >> "$NEW"
cat "$NEW" > "$DST"                                        # in place: keeps owner and mode 600
echo "==> $DST now has: $(grep -o '^GRAFANA_SMTP_[A-Z]*' "$DST" | tr '\n' ' ')"
echo "    next: ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'"
