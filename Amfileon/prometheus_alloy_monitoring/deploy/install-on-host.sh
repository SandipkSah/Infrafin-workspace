#!/usr/bin/env bash
# Runs ON the server, by a person (asks for the sudo password once). Staged by stage.sh as
# ~/install-<service>.sh. Installs ~/<service>-deploy/ into /srv/docker/<service>/ and starts it.
#
#   ssh -t <host> 'bash ~/install-<service>.sh'
#
# Files stay ssa-owned (cp -a) until the final lockdown step in deploy/README.md.
set -euo pipefail

SERVICE=${1:?service}          # prometheus | alloy
VHOST=${2:-}                   # e.g. db2.prometheus.amf — certificate to make sure nginx-proxy has
SRC=~/"$SERVICE-deploy"
DEST=/srv/docker/$SERVICE

echo "==> starting $SERVICE in $DEST (sudo password needed once)"
sudo -v

if [ -d "$SRC" ]; then
  sudo mkdir -p "$DEST"
  sudo cp -a "$SRC"/. "$DEST"/
  rm -r "$SRC"
elif [ -e "$DEST/docker-compose.yaml" ]; then
  echo "    files already in place in $DEST"
else
  echo "nothing staged in $SRC and no $DEST/docker-compose.yaml" >&2; exit 1
fi

if [ -n "$VHOST" ]; then
  if sudo docker exec nginx-proxy test -f "/etc/nginx/certs/$VHOST.crt"; then
    echo "==> nginx-proxy already has the certificate for $VHOST"
  else
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
fi

cd "$DEST"
sudo docker compose config -q
sudo docker compose up -d
sleep 8
echo "==> status"
sudo docker compose ps
echo "==> last log lines"
sudo docker compose logs --tail 25 --no-color

echo "==> done. Tell Claude to verify."
