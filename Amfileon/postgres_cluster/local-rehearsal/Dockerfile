# Local rehearsal image: Postgres + Patroni bundled (the "DIY" option from the runbook).
# Native arm64 build on the Mac. NOT for production — no TLS, throwaway.
FROM postgres:16
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip python3-psycopg2 curl ca-certificates \
 && pip3 install --break-system-packages "patroni[etcd3]" \
 && rm -rf /var/lib/apt/lists/*
# Patroni is PID 1 and spawns Postgres as a child (compose sets the entrypoint + config mount).
