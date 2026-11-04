#!/usr/bin/env bash
# Prepares build/ and .env for the rehearsal — using the production code paths:
#   - Alloy config:  deploy/alloy/gen_services.py --targets rehearsal-targets.txt (+ deploy's http.alloy)
#   - ClickHouse:    the <prometheus> insertion from deploy/services/enable-clickhouse-metrics.sh
#   - Redis TLS:     a throw-away test CA + certificate for production.redis.amf
# Re-running keeps .env and the certificates.
set -euo pipefail
cd "$(dirname "$0")"
B=build
mkdir -p "$B"/{alloy,clickhouse,certs,gen}

# passwords (local only)
if [ ! -f .env ]; then
  printf 'REDIS_PROD_PW=%s\nALLOY_HTTP_PASSWORD=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env
fi
# shellcheck disable=SC1091
. ./.env
printf "REDIS_PASSWORD_REDIS_PRODUCTION_DB1='%s'\n" "$REDIS_PROD_PW" > "$B/redis.env"

# test CA + server certificate for the TLS Redis
if [ ! -f "$B/certs/redis.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=rehearsal-ca" \
    -keyout "$B/certs/ca.key" -out "$B/certs/ca.pem" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=production.redis.amf" \
    -keyout "$B/certs/redis.key" -out "$B/certs/redis.csr" 2>/dev/null
  printf 'subjectAltName=DNS:production.redis.amf\n' > "$B/certs/san.ext"
  openssl x509 -req -in "$B/certs/redis.csr" -CA "$B/certs/ca.pem" -CAkey "$B/certs/ca.key" \
    -CAcreateserial -days 30 -extfile "$B/certs/san.ext" -out "$B/certs/redis.crt" 2>/dev/null
  chmod 644 "$B/certs/"*   # read by the redis user in the container (test material only)
fi

# Alloy: generated services config + production http.alloy + rehearsal remote_write
python3 ../deploy/alloy/gen_services.py --targets rehearsal-targets.txt --out "$B/gen"
cp "$B/gen/db1.services.alloy" "$B/alloy/services.alloy"
cp ../deploy/alloy/config/http.alloy alloy/rehearsal.alloy "$B/alloy/"

# ClickHouse: base files + the block exactly as enable-clickhouse-metrics.sh inserts it
sed -n "/^python3 - /,/^PY$/p" ../deploy/services/enable-clickhouse-metrics.sh | sed '1d;$d' > "$B/edit_clickhouse.py"
python3 "$B/edit_clickhouse.py" clickhouse/keeper.xml "$B/clickhouse/keeper.xml" keeper
python3 "$B/edit_clickhouse.py" clickhouse/config.xml "$B/clickhouse/config.xml" server
chmod 644 "$B/clickhouse/"*.xml

echo "ready: docker compose up -d   then   open http://localhost:3002 (admin/admin)"
