#!/usr/bin/env bash
# Run by YOU from your Mac (VPN on). Fills the two empty values in db1's
# /srv/docker/prometheus/.env — nothing secret is printed:
#   SMTP_PASSWORD          copied on db1 from WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD
#                          in /srv/docker/watchtower/.env (same mail account)
#   HEALTHCHECKS_PING_URL  asked for here (paste the healthchecks.io ping URL)
set -euo pipefail

read -r -p "healthchecks.io ping URL for the Watchdog (Enter = skip for now): " HC_URL
case "$HC_URL" in
  "") echo "→ skipping: Watchdog heartbeat stays OFF until you run this again with a URL" ;;
  https://*) ;;
  *) echo "doesn't look like a URL — aborting" >&2; exit 1 ;;
esac

# The URL travels over ssh's stdin, not the command line.
printf '%s\n' "$HC_URL" | ssh db1 'python3 -c "
import sys
hc = sys.stdin.readline().strip()
src, dst = \"/srv/docker/watchtower/.env\", \"/srv/docker/prometheus/.env\"
pw = next((l.rstrip(\"\n\").split(\"=\", 1)[1] for l in open(src)
           if l.startswith(\"WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD=\")), \"\")
out, set_pw, set_hc = [], False, False
for l in open(dst).read().splitlines():
    if l.startswith(\"SMTP_PASSWORD=\") and pw:
        l, set_pw = \"SMTP_PASSWORD=\" + pw, True
    elif l.startswith(\"HEALTHCHECKS_PING_URL=\") and hc:
        l, set_hc = \"HEALTHCHECKS_PING_URL=\" + hc, True
    out.append(l)
open(dst, \"w\").write(\"\n\".join(out) + \"\n\")
print(\"SMTP_PASSWORD set:\", set_pw, \"| HEALTHCHECKS_PING_URL set:\", set_hc)
"
chmod 600 /srv/docker/prometheus/.env
echo "still empty: $(grep -E "^[A-Z_]+=$" /srv/docker/prometheus/.env | cut -d= -f1 | tr "\n" " ")"'
echo "If Alertmanager is already running, apply with:"
echo "  ssh -t db1 'cd /srv/docker/prometheus && sudo docker compose up -d alertmanager'"
