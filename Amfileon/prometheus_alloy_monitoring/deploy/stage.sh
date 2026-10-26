#!/usr/bin/env bash
# Copies a service's files into ~/<service>-deploy/ on a host — over plain ssh/scp, NO root.
# The root part (copy into /srv/docker/<service>, docker compose up) is done by hand; see the
# INSTALL.md files. Secrets travel inside .env and are never printed.
#
#   ./stage.sh prometheus db1|db2
#   ./stage.sh alloy      db1|db2|cpu1|cpu2|gpu1|prod3
set -euo pipefail
cd "$(dirname "$0")"

SERVICE=${1:?usage: $0 prometheus|alloy <host>}
HOST=${2:?usage: $0 prometheus|alloy <host>}
case "$HOST" in   # macOS bash 3.2: no associative arrays
  db1) HOST_IP=10.10.10.20 ;;  db2) HOST_IP=10.10.10.21 ;;
  cpu1) HOST_IP=10.10.10.30 ;; cpu2) HOST_IP=10.10.10.31 ;;
  gpu1) HOST_IP=10.10.10.40 ;; prod3) HOST_IP=10.10.10.13 ;;
  *) echo "unknown host: $HOST" >&2; exit 1 ;;
esac
[ -d secrets ] || { echo "run ./gen-secrets.sh first" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -r "$STAGE"' EXIT
umask 077

case "$SERVICE" in
  prometheus)
    [ "$HOST" = db1 ] || [ "$HOST" = db2 ] || { echo "prometheus runs on db1/db2 only" >&2; exit 1; }
    cp "$HOST"/prometheus/{docker-compose.yaml,prometheus.yml} "$STAGE/"
    if [ "$HOST" = db1 ]; then
      cp db1/prometheus/{alert.rules,alertmanager.yml} ca/amfileon-ca.pem "$STAGE/"
      cp nginx/prometheus_location "$STAGE/nginx_location"
      cp secrets/prometheus-db1.env "$STAGE/.env"
      # non-secret alerting settings; SMTP_PASSWORD and HEALTHCHECKS_PING_URL are filled in on db1
      sed -n '/^# who gets alert emails/,$p' db1/prometheus/.env.example \
        | sed -e 's/^SMTP_PASSWORD=.*/SMTP_PASSWORD=/' -e 's/^HEALTHCHECKS_PING_URL=.*/HEALTHCHECKS_PING_URL=/' \
        | { echo; cat; } >> "$STAGE/.env"
    else
      cp secrets/prometheus.env "$STAGE/.env"
      cp nginx/prometheus_location "$STAGE/nginx_location"
    fi
    ;;
  alloy)
    mkdir "$STAGE/config"
    cp alloy/docker-compose.yaml ca/amfileon-ca.pem "$STAGE/"
    cp alloy/config/*.alloy "$STAGE/config/"        # common.alloy + http.alloy
    cp "alloy/hosts/$HOST.alloy" "$STAGE/config/host.alloy"
    for extra in alloy/hosts/"$HOST".*.alloy; do [ -f "$extra" ] && cp "$extra" "$STAGE/config/${extra##*/$HOST.}"; done   # e.g. db1.certificates.alloy → certificates.alloy
    { cat secrets/alloy.env; printf 'AMF_HOST=%s\nAMF_HOST_IP=%s\n' "$HOST" "$HOST_IP"; } > "$STAGE/.env"
    ;;
  *) echo "unknown service: $SERVICE" >&2; exit 1 ;;
esac

scp -q install-on-host.sh "$HOST:install-$SERVICE.sh"
if ssh "$HOST" "test -d /srv/docker/$SERVICE -a -w /srv/docker/$SERVICE"; then
  # /srv/docker/<service> was pre-created owned by ssa → put the files straight in place
  DEST=/srv/docker/$SERVICE
  # never overwrite a .env that is already there (it may hold values filled in on the server)
  if [ "$SERVICE" = prometheus ] && ssh "$HOST" "test -f $DEST/.env"; then
    rm "$STAGE/.env"
    echo "(kept the existing $DEST/.env on $HOST)"
  fi
  scp -rq "$STAGE"/. "$HOST:$DEST/"
  # configs must be readable by the container users (Prometheus runs as nobody);
  # only .env stays private (docker compose reads it as root)
  ssh "$HOST" "find $DEST -type d -exec chmod 755 {} + && find $DEST -type f ! -name .env -exec chmod 644 {} + && chmod 600 $DEST/.env"
else
  DEST="~/$SERVICE-deploy"
  ssh "$HOST" "rm -rf ~/$SERVICE-deploy && mkdir -m 700 ~/$SERVICE-deploy"
  scp -rq "$STAGE"/. "$HOST:$SERVICE-deploy/"
fi
echo "Staged on $HOST:$DEST/ :"
ssh "$HOST" "cd $DEST && find . -type f | sort | xargs stat -c '  %A %U %n'"

VHOST=""
[ "$SERVICE" = prometheus ] && VHOST="$HOST.prometheus.amf"
echo
echo "Install with (asks for the sudo password once):"
echo "  ssh -t $HOST 'bash ~/install-$SERVICE.sh $SERVICE $VHOST'"
