#!/usr/bin/env bash
# Dedicated CA for the Amfileon Postgres-HA etcd cluster ONLY — deliberately separate
# from the org-wide amf CA. Supersedes gen-etcd-certs.sh (which assumed reuse of the
# existing amf CA / its private key). We pivoted because:
#   - the mTLS etcd cluster (db1/db2, port 2379) was NEVER successfully used by anything
#     (Patroni was blocked by the missing clientAuth EKU on the old server certs) — so
#     there is no live data or trust relationship to preserve.
#   - the old etcd ca.key's location was unclear (plain openssl was reportedly used to sign,
#     but not with that specific ca.key file) — rather than chase down the original signing
#     key, we mint a fresh CA scoped ONLY to this cluster. Nothing else in the firm trusts
#     it, so there is zero blast radius to starting clean.
#
# Run once (e.g. on db2, in /srv/docker/pg-cluster-instance-2/pki/), producing per-host
# folders ready to scp out. IMPORTANT: move ca.key off any shared host once done — it is
# the trust root for this cluster's etcd; don't leave it parked on a production box.
set -euo pipefail
OUT="${1:-./pki}"
mkdir -p "$OUT"; cd "$OUT"

CA_DAYS=7300     # 20y
LEAF_DAYS=3650   # 10y

echo "== generating root CA =="
openssl genrsa -out ca.key 4096
openssl req -new -x509 -key ca.key -days "$CA_DAYS" -sha256 \
  -subj "/CN=amfileon-pgcluster-ca" -out ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

sign_leaf() { # name cn eku sanlist(or -)
  local name=$1 cn=$2 eku=$3 sanlist=$4
  local ext="${name}.ext.cnf"
  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=$eku"
    if [ "$sanlist" != "-" ]; then
      echo "subjectAltName=@alt"; echo "[alt]"
      local ip=1 dns=1
      IFS=',' read -ra parts <<< "$sanlist"
      for p in "${parts[@]}"; do
        if [[ "$p" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "IP.$((ip++)) = $p"
        else
          echo "DNS.$((dns++)) = $p"
        fi
      done
    fi
  } > "$ext"
  openssl genrsa -out "${name}.key" 3072
  openssl req -new -key "${name}.key" -subj "/CN=$cn" -out "${name}.csr"
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$LEAF_DAYS" -sha256 -extfile "$ext" -out "${name}.crt"
  rm -f "${name}.csr" "$ext"
}

DUAL="serverAuth,clientAuth"   # the fix — both usages on server AND peer certs.
                                # etcd's embedded JSON gRPC-gateway self-dials its own
                                # gRPC server presenting the SERVER cert as a client
                                # credential; with client-cert-auth=true a serverAuth-only
                                # cert is rejected ("tls: bad certificate") on every /v3
                                # call, which is exactly how Patroni's etcd3 client talks.
                                # Root-caused 2026-07-17 against the original amf-CA certs.

for entry in "db1:etcd1:10.10.10.20" "db2:etcd2:10.10.10.21" "prod3:etcd3:10.10.10.13"; do
  host="${entry%%:*}"; rest="${entry#*:}"; member="${rest%%:*}"; ip="${rest#*:}"
  mkdir -p "$host"
  echo "== signing $member (host $host, ip $ip) =="
  sign_leaf "$host/$member.server" "$member" "$DUAL"      "$ip,127.0.0.1,$member,localhost"
  sign_leaf "$host/$member.peer"   "$member" "$DUAL"      "$ip,127.0.0.1,$member,localhost"
  sign_leaf "$host/$member.client" "$member" "clientAuth" "-"
  cp ca.crt "$host/ca.crt"
done

echo; echo "================ ACCEPTANCE CHECK ================"
for f in db1/*.crt db2/*.crt prod3/*.crt; do
  [ "$(basename "$f")" = "ca.crt" ] && continue
  echo "-- $f --"
  echo -n "  EKU: "; openssl x509 -in "$f" -noout -text | grep -A1 "Extended Key Usage" | tail -1 | xargs
  echo -n "  SAN: "; openssl x509 -in "$f" -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | xargs || echo "(none - expected for client certs)"
  echo -n "  Chain: "; openssl verify -CAfile ca.crt "$f"
done

echo; echo "Tree:"; find . -maxdepth 2 -type f | sort
