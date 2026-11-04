#!/usr/bin/env bash
# Runs ON the server, by a person (asks for the sudo password once). Staged by stage.sh as
# ~/install-<service>.sh. Installs ~/<service>-deploy/ into /srv/docker/<service>/ and starts it.
#
#   ssh -t <host> 'bash ~/install-<service>.sh'
#
# Files stay ssa-owned (cp -a) until the final lockdown step in deploy/README.md.
set -euo pipefail

SERVICE=${1:?service}          # prometheus | alloy | grafana-dashboards
VHOST=${2:-}                   # e.g. db2.prometheus.amf — certificate to make sure nginx-proxy has
SRC=~/"$SERVICE-deploy"
DEST=/srv/docker/$SERVICE

echo "==> starting $SERVICE in $DEST (sudo password needed once)"
sudo -v

if [ -d "$SRC" ]; then
  # never copy over a service someone else set up under the same name
  if sudo test -f "$DEST/docker-compose.yaml" && ! sudo grep -q prometheus_alloy_monitoring "$DEST/docker-compose.yaml" \
     && ! sudo grep -q 'Alloy\|alloy\|Prometheus' "$DEST/docker-compose.yaml"; then
    echo "$DEST exists and is not from prometheus_alloy_monitoring — stopping, nothing changed" >&2; exit 1
  fi
  # values filled in on the server (SMTP, admin password) must survive; Alloy's .env is regenerated
  if [ "$SERVICE" != alloy ] && sudo test -f "$DEST/.env"; then rm -f "$SRC/.env"; fi
  OWNER=$(sudo stat -c %U "$DEST" 2>/dev/null || echo ssa)
  sudo mkdir -p "$DEST"
  sudo cp -a "$SRC"/. "$DEST"/
  rm -r "$SRC"
  # already locked down (deploy/README.md step 6): stay root-owned, ssa must not get write access back
  [ "$OWNER" != root ] || sudo chown -R root:root "$DEST"
  # staged files are 600 (umask 077); the containers run as their own users (Prometheus: nobody,
  # Grafana: 472) and must be able to read configs — only the env files stay private
  sudo find "$DEST" -type d -exec chmod 755 {} +
  sudo find "$DEST" -type f ! -name '*.env' ! -name .env -exec chmod 644 {} +
  sudo chmod 600 "$DEST/.env"
elif [ -e "$DEST/docker-compose.yaml" ]; then
  echo "    files already in place in $DEST"
else
  echo "nothing staged in $SRC and no $DEST/docker-compose.yaml" >&2; exit 1
fi

if [ -n "$VHOST" ]; then
  if sudo docker exec nginx-proxy test -f "/etc/nginx/certs/$VHOST.crt"; then
    echo "==> nginx-proxy already has the certificate for $VHOST"
  else
    sudo test -f "/srv/docker/proxy/$VHOST.crt" -a -f "/srv/docker/proxy/$VHOST.key" \
      || { echo "/srv/docker/proxy/$VHOST.crt/.key missing — create the certificate first" >&2; exit 1; }
    CERTS=$(sudo docker volume inspect -f '{{.Mountpoint}}' proxy_certs)
    sudo cp "/srv/docker/proxy/$VHOST.crt" "/srv/docker/proxy/$VHOST.key" "$CERTS/"
    echo "==> copied the $VHOST certificate into nginx-proxy's certs volume"
  fi
fi

if [ -n "$VHOST" ] && [ -f "$DEST/nginx_location" ]; then
  VHOSTD=$(sudo docker volume inspect -f '{{.Mountpoint}}' proxy_vhost)
  sudo cp "$DEST/nginx_location" "$VHOSTD/${VHOST}_location"
  echo "==> installed nginx least-privilege rule as vhost.d/${VHOST}_location"
fi

if [ "$SERVICE" = alloy ]; then
  sudo docker network inspect dockprom_monitor-net >/dev/null \
    || { echo "dockprom_monitor-net network not found — is dockprom running?" >&2; exit 1; }
  # Redis passwords (filled by ~/fill-redis-env.sh); compose needs the file even when empty
  sudo test -f "$DEST/redis.env" || sudo install -m 600 -o root -g root /dev/null "$DEST/redis.env"
fi

cd "$DEST"
sudo docker compose config -q
if [ "$SERVICE" = prometheus ]; then
  sudo docker compose up -d
  # Prometheus reads alert.rules / prometheus.yml only at start or on SIGHUP, and `up -d` leaves it
  # running when only those files changed — reload them (no restart, no gap)
  sudo docker compose kill -s SIGHUP prometheus
else
  # Alloy and Grafana read their config files only at start, and `up -d` does not recreate a
  # container when only those files changed — so always recreate (state lives in the volumes)
  sudo docker compose up -d --force-recreate
fi
sleep 8
echo "==> status"
sudo docker compose ps
echo "==> last log lines"
sudo docker compose logs --tail 25 --no-color

echo "==> done. Tell Claude to verify."
