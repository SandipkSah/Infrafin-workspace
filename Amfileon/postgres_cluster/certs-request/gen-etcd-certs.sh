#!/usr/bin/env bash
# ⚠️ SUPERSEDED (2026-07-21) — see gen-pgcluster-ca.sh instead.
# This script assumed reissue via the existing amf CA (its private key). That plan was
# abandoned: it was confirmed the original certs were signed with plain openssl but not
# using that ca.key file specifically — its actual location/existence is unresolved, and
# the mTLS etcd cluster these certs serve was never successfully used by anything (Patroni
# was blocked by the missing EKU from the start). Zero blast radius to starting fresh, so
# we mint a brand-new, dedicated CA instead — see gen-pgcluster-ca.sh. Kept here only as a
# historical record of the original (org-CA) plan.
#
# gen-etcd-certs.sh — regenerate/mint the etcd certs for the Postgres-HA cluster.
#
# RUN THIS NEXT TO THE amf CA MATERIAL (needs ca.crt + ca.key in $CA_DIR).
# Produces, in ./out :
#   etcd1.server.crt/.key   (db1  10.10.10.20)  EKU serverAuth+clientAuth   <- REISSUE
#   etcd2.server.crt/.key   (db2  10.10.10.21)  EKU serverAuth+clientAuth   <- REISSUE
#   etcd3.server.crt/.key   (prod3 10.10.10.13) EKU serverAuth+clientAuth   <- NEW
#   etcd3.peer.crt/.key     (prod3)             EKU serverAuth+clientAuth   <- NEW
#   etcd3.client.crt/.key   (prod3)             EKU clientAuth              <- NEW
#
# WHY dual EKU on server certs: etcd's embedded gRPC-gateway self-dials its own
# gRPC endpoint presenting the SERVER cert as a client credential; with
# --client-cert-auth=true a serverAuth-only cert is rejected ("tls: bad
# certificate"), breaking every /v3 JSON consumer (Patroni). Diagnosed 2026-07-17.
#
# Existing etcd1/etcd2 peer+client certs are untouched (verified fine).
# To reuse existing private keys instead of minting new ones, place them in
# ./out under the target name BEFORE running (the script skips genrsa if present).

set -euo pipefail
CA_DIR="${CA_DIR:-.}"           # where ca.crt + ca.key live
DAYS="${DAYS:-3650}"
OUT=out; mkdir -p "$OUT"

sign() { # sign <name> <cn> <eku> <san or ->
  local name=$1 cn=$2 eku=$3 san=$4
  local ext="$OUT/$name.ext"
  {
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    if [ "$san" != "-" ]; then
      echo "subjectAltName = @alt"; echo "[alt]"
      local i_ip=1 i_dns=1
      IFS=',' read -ra parts <<< "$san"
      for p in "${parts[@]}"; do
        case "$p" in
          [0-9]*) echo "IP.$((i_ip++)) = $p" ;;
          *)      echo "DNS.$((i_dns++)) = $p" ;;
        esac
      done
    fi
  } > "$ext"
  [ -f "$OUT/$name.key" ] || openssl genrsa -out "$OUT/$name.key" 3072
  openssl req -new -key "$OUT/$name.key" -subj "/CN=$cn" -out "$OUT/$name.csr"
  openssl x509 -req -in "$OUT/$name.csr" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
    -days "$DAYS" -sha256 -extfile "$ext" -out "$OUT/$name.crt"
  rm -f "$OUT/$name.csr" "$ext"
  echo "signed: $name"
}

DUAL="serverAuth, clientAuth"

sign etcd1.server etcd1 "$DUAL" "10.10.10.20,127.0.0.1,etcd1,localhost"
sign etcd2.server etcd2 "$DUAL" "10.10.10.21,127.0.0.1,etcd2,localhost"
sign etcd3.server etcd3 "$DUAL" "10.10.10.13,127.0.0.1,etcd3,localhost"
sign etcd3.peer   etcd3 "$DUAL" "10.10.10.13,127.0.0.1,etcd3,localhost"
sign etcd3.client etcd3 "clientAuth" "-"

echo; echo "=== acceptance check ==="
for f in "$OUT"/*.crt; do
  echo "== $f"
  openssl x509 -in "$f" -noout -text | grep -A1 "Extended Key Usage" | tail -1
  openssl x509 -in "$f" -noout -text | grep -A1 "Subject Alternative Name" | tail -1 || true
  openssl verify -CAfile "$CA_DIR/ca.crt" "$f"
done
echo "Done. Deliver ./out to the db hosts (keys 0600; the Patroni copy chowned 101:103)."
