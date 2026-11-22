#!/usr/bin/env bash
# docker compose for the Alloy log rehearsal: the REAL deploy/alloy/docker-compose.yaml + override.yaml,
# all relative paths resolved in this folder.   ./compose.sh up -d | logs | down
cd "$(dirname "$0")"
# dummy values only (nothing leaves the Mac); start ../ (Loki + MinIO) first
[ -f .env ] || printf 'ALLOY_PASSWORD=x\nAMF_HOST=rehearsal\nALLOY_HTTP_PASSWORD=rehearsal\nLOKI_PASSWORD=x\nAMF_HOST_IP=127.0.0.1\n' > .env
[ -f amfileon-ca.pem ] || cp ../../deploy/ca/amfileon-ca.pem .
docker network inspect dockprom_monitor-net >/dev/null 2>&1 || docker network create dockprom_monitor-net >/dev/null
cp ../../deploy/alloy/config/logs.alloy ../../deploy/alloy/config/http.alloy config/
exec docker compose -p alloy-logs-rehearsal --project-directory . --env-file .env \
  -f ../../deploy/alloy/docker-compose.yaml -f override.yaml "$@"
