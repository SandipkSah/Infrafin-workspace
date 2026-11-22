#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Makes the existing Loki (/srv/docker/grafana-loki) keep logs for
# N days (default 30) and delete everything older from its S3 bucket.
#
#   scp deploy/loki/enable-loki-retention.sh db1:
#   ssh -t db1 'bash ~/enable-loki-retention.sh'        # 30 days
#   ssh -t db1 'bash ~/enable-loki-retention.sh 90'     # other value
#
# 2026-11-11: first run set 90 days; changed to 30 days the same day (second run updates the value).
#
# What it changes in loki-config.yaml (nothing else, no compose change):
#   limits_config.retention_period: <N×24>h    (N days)
#   compactor: retention_enabled …             (new section; the compactor is what deletes)
# The config is checked with Loki's own -verify-config before Loki is restarted; a copy of the
# original goes to /root/loki-config-backups/ (not into /srv/docker/grafana-loki, a git checkout).
#
# Effect: Loki restarts (~10 s; promtail retries, nothing is lost). About 2 h later the compactor
# starts deleting chunks older than N days — THIS CANNOT BE UNDONE. Space in the bucket comes back
# over the following hours. Running it again with the same N changes nothing; another N updates it.
set -euo pipefail
# LOKI_DIR / LOKI_DAYS / LOKI_DELETE_DELAY / LOKI_COMPACTION_INTERVAL / LOKI_NO_SUDO exist only for
# the local rehearsal (loki-rehearsal/); on db1 the defaults are used.
[ "$(id -u)" = 0 ] || [ -n "${LOKI_NO_SUDO:-}" ] || exec sudo bash "$0" "$@"

DIR=${LOKI_DIR:-/srv/docker/grafana-loki}
F=$DIR/loki-config.yaml
DAYS=${1:-${LOKI_DAYS:-30}}
case "$DAYS" in ""|*[!0-9]*) echo "days must be a number" >&2; exit 1 ;; esac
DELAY=${LOKI_DELETE_DELAY:-2h}
INTERVAL=${LOKI_COMPACTION_INTERVAL:-10m}
BKDIR=${LOKI_BACKUP_DIR:-/root/loki-config-backups}
IMAGE=$(sed -n 's/^ *image: *\(grafana\/loki:[^ ]*\).*/\1/p' "$DIR/docker-compose.yaml" | head -1)
[ -f "$F" ] && [ -n "$IMAGE" ] || { echo "no $F or no grafana/loki image in the compose file" >&2; exit 1; }

MODE=add
if grep -qE '^compactor:' "$F" || grep -qE '^\s+retention_period:' "$F"; then
  if grep -qE "^\s+retention_period: $((DAYS*24))h" "$F"; then
    echo "retention already $DAYS days in $F — nothing changed:"; grep -nE 'retention|^compactor' "$F"; exit 0
  fi
  grep -qE '^compactor:' "$F" && grep -qE '^\s+retention_period:' "$F" \
    || { echo "unexpected: only one of compactor/retention_period in $F — nothing changed" >&2; exit 1; }
  MODE=update
fi

BK=$BKDIR/loki-config.yaml.$(date +%F-%H%M%S)
mkdir -p "$BKDIR" && chmod 700 "$BKDIR"
cp -a "$F" "$BK"
NEW=$(mktemp); trap 'rm -f "$NEW"' EXIT

python3 - "$F" "$NEW" "$DAYS" "$DELAY" "$INTERVAL" "$MODE" <<'PY'
import re, sys
src, dst, days, delay, interval, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
lines = open(src).read().splitlines()
if mode == "update":
    n = 0
    for k, l in enumerate(lines):
        if re.match(r"^\s+retention_period:\s*\d+h", l):
            lines[k] = f"  retention_period: {days * 24}h        # {days} days (enable-loki-retention.sh)"; n += 1
    if n != 1:
        sys.exit(f"expected exactly one retention_period line, found {n}")
    open(dst, "w").write("\n".join(lines) + "\n"); sys.exit(0)
i = next((n for n, l in enumerate(lines) if re.fullmatch(r"limits_config:\s*", l)), None)
if i is None:
    sys.exit("no top-level 'limits_config:' line found")
lines.insert(i + 1, f"  retention_period: {days * 24}h        # {days} days (enable-loki-retention.sh)")
lines += ["",
          "# deletes logs older than limits_config.retention_period (enable-loki-retention.sh)",
          "compactor:",
          "  working_directory: /loki/compactor",
          "  shared_store: s3",
          f"  compaction_interval: {interval}",
          "  retention_enabled: true",
          f"  retention_delete_delay: {delay}",
          "  retention_delete_worker_count: 150"]
open(dst, "w").write("\n".join(lines) + "\n")
PY

echo "==> checking the new config with $IMAGE -verify-config"
# --user 0: the temp file is root-only (mode 600, it holds the S3 keys); Loki's image runs as 10001
if ! docker run --rm --user 0 -v "$NEW:/etc/loki/c.yaml:ro" "$IMAGE" -config.file=/etc/loki/c.yaml -verify-config; then
  echo "config check FAILED — nothing changed, Loki not restarted" >&2; exit 1
fi

cat "$NEW" > "$F"          # keep owner/permissions of the original file
echo "==> diff"; diff "$BK" "$F" || true

echo "==> restarting Loki"
cd "$DIR"; docker compose restart loki
for i in $(seq 1 30); do
  [ "$(curl -s -m 2 http://127.0.0.1:3100/ready)" = "ready" ] && break; sleep 2
done
curl -s -m 5 http://127.0.0.1:3100/ready; echo
echo "==> active settings (expect retention_enabled: true, retention_period: $((DAYS*24))h)"
curl -s -m 5 http://127.0.0.1:3100/config | grep -E '^\s+(retention_enabled|retention_period|retention_delete_delay):' | sort | uniq -c

cat <<EOF

Done. Deletion of logs older than $DAYS days starts in about $DELAY.
Rollback (before $DELAY is over):
  sudo cp $BK $F && cd $DIR && sudo docker compose restart loki
EOF
