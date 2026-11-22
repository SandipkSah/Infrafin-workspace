#!/usr/bin/env bash
# Runs ON db1, by a person (sudo). Gives the existing Loki (/srv/docker/grafana-loki, not set up by us)
# the data volume it is missing — the standard setup — and recreates it WITHOUT losing logs:
#
#   compose:  loki service gets  - loki_data:/loki   (+ top-level  volumes: loki_data)
#
# Why: everything under /loki (WAL = logs not yet in S3, the index of the last minutes, compactor
# state) lives inside the container today. A plain restart is fine; a RECREATE (compose up after a
# change, image update) silently loses the WAL. Rehearsed 2026-11-13 (loki-rehearsal/): a recreate
# without flush lost 200/200 recent lines; with this procedure and a writer pushing nonstop:
# 207 sent, 207 found, 0 missing. With the volume, a later recreate or even `docker kill` lost nothing.
#
#   scp deploy/loki/add-loki-volume.sh db1:
#   ssh -t db1 'bash ~/add-loki-volume.sh'           # dry run: checks + shows the compose change
#   ssh -t db1 'bash ~/add-loki-volume.sh --apply'   # do it (~3–5 min)
#
# --apply:
#   1. backup of docker-compose.yaml → /root/loki-config-backups/
#   2. counts the logs of a fixed 10-min window (for the before/after check)
#   3. POST /ingester/shutdown?flush=true&terminate=false — the RUNNING Loki writes everything it holds
#      to S3 (MinIO) and stops accepting writes; Alloy/promtail get errors and retry (they buffer)
#   4. writes the new compose and recreates ONLY loki (--no-deps: grafana in the same file untouched),
#      stop timeout 120 s so Loki can upload its index on the way down
#   5. waits for /ready, checks the volume is mounted, counts the same window again (must be equal)
#   If the new Loki does not get ready: the old compose file is restored and Loki recreated as before.
#
# Side effect (wanted): the old container's 30 GB json log is deleted with it, and the new container
# gets db1's Docker log limit (100m × 5). filebeat keeps deleted log files open → the space only comes
# back after filebeat is restarted (the script tells you; it does not do it).
set -euo pipefail
APPLY=${1:-}
[ "$(id -u)" = 0 ] || [ -n "${LOKI_NO_SUDO:-}" ] || exec sudo bash "$0" "$@"
DIR=${LOKI_DIR:-/srv/docker/grafana-loki}
F=$DIR/docker-compose.yaml
C=${LOKI_CONTAINER:-grafana-loki-loki-1}
L=${LOKI_URL_LOCAL:-http://localhost:3100}
BKDIR=${LOKI_BACKUP_DIR:-/root/loki-config-backups}

echo "==> $(hostname): Loki data volume $( [ "$APPLY" = --apply ] && echo '(APPLY)' || echo '(dry run — add --apply)')"
docker inspect "$C" >/dev/null 2>&1 || { echo "    container $C not found" >&2; exit 1; }
if docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$C" | grep -qx /loki; then
  echo "    $C already has a mount on /loki — nothing to do"; exit 0; fi
files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$C")
[ "$files" = "$F" ] || { echo "    $C was started from '$files', not $F — stopping, check by hand" >&2; exit 1; }
curl -sf "$L/ready" >/dev/null || { echo "    Loki is not ready at $L — stopping" >&2; exit 1; }

# ---- the compose change (exact anchors; refuses if the file looks different) ----------------------
NEW=$(mktemp "$DIR/.docker-compose.new.XXXXXX"); trap 'rm -f "$NEW"' EXIT
python3 - "$F" "$NEW" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
if any("loki_data" in l for l in lines):
    sys.exit("    loki_data already in the compose file but not mounted — check by hand")
anchor = "      - ./loki-config.yaml:/etc/loki/loki-config.yaml"
hits = [i for i, l in enumerate(lines) if l.rstrip() == anchor]
if len(hits) != 1:
    sys.exit(f"    expected the line '{anchor.strip()}' exactly once, found {len(hits)} — check by hand")
# the anchor must be inside the 'loki:' service
svc = [i for i, l in enumerate(lines[:hits[0]]) if re.match(r"^  [A-Za-z0-9_-]+:\s*$", l)]
if not svc or lines[svc[-1]].strip() != "loki:":
    sys.exit("    the config mount is not inside the loki service — check by hand")
lines.insert(hits[0] + 1, "      - loki_data:/loki        # WAL, local index, compactor (add-loki-volume.sh)")
top = [i for i, l in enumerate(lines) if re.match(r"^volumes:", l)]
if top:
    if lines[top[0]].strip() != "volumes:":
        sys.exit("    top-level 'volumes:' is not in block form — check by hand")
    lines.insert(top[0] + 1, "  loki_data: {}")
else:
    while lines and lines[-1] == "": lines.pop()
    lines += ["", "volumes:", "  loki_data: {}", ""]
open(dst, "w").write("\n".join(lines))
PY
echo "--- change to $F"
diff "$F" "$NEW" | sed 's/^/    /' || true
echo "--- docker compose config check (output hidden: the file contains secrets via .env)"
( cd "$DIR" && docker compose -f "$NEW" config -q ) && echo "    valid"
( cd "$DIR" && docker compose -f "$NEW" config --volumes ) | grep -qx loki_data && echo "    named volume loki_data declared"

LP=$(docker inspect -f '{{.LogPath}}' "$C")
echo "--- old container's Docker log (deleted with it): $( { du -ch "$LP"* 2>/dev/null || true; } | tail -1 | cut -f1)"

if [ "$APPLY" != --apply ]; then echo "==> dry run done — nothing changed (run again with --apply)"; exit 0; fi

# ---- apply -----------------------------------------------------------------------------------------
count() {   # lines of all streams in the 10 min before $1 (ns)
  curl -sf -G "$L/loki/api/v1/query" --data-urlencode 'query=sum(count_over_time({job=~".+"}[10m]))' \
    --data-urlencode "time=$1" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else 0)'
}
mkdir -p "$BKDIR" && chmod 700 "$BKDIR"
BK=$BKDIR/docker-compose.yaml.$(date +%F-%H%M%S); cp -a "$F" "$BK"
echo "--- backup: $BK"
T=$(( ($(date +%s) - 120) * 1000000000 ))
BEFORE=$(count "$T"); echo "--- lines in the check window (10 min up to 2 min ago): $BEFORE"

echo "--- 3. flush everything to S3 and stop accepting writes (Alloy/promtail retry meanwhile)"
S=$(date +%s)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 900 -X POST "$L/ingester/shutdown?flush=true&terminate=false")
echo "    → HTTP $code after $(( $(date +%s) - S )) s"
[ "$code" = 204 ] || { echo "    flush did not succeed — NOTHING changed except: Loki may not accept writes; run: cd $DIR && docker compose restart loki" >&2; exit 1; }

echo "--- 3b. copy of the container's /loki (WAL, index not yet uploaded, compactor) — deleted by the recreate"
DBK=${LOKI_DATA_BACKUP:-/root/loki-data-backup-$(date +%F-%H%M%S)}
need=$(docker exec "$C" du -sk /loki | cut -f1); free=$(df -Pk "$(dirname "$DBK")" | awk 'NR==2{print $4}')
echo "    /loki is $((need/1024)) MB, free next to $DBK: $((free/1024)) MB"
if [ "$free" -lt $((need * 2 + 1048576)) ]; then
  echo "    not enough space for a safe copy — stopping before any change. Loki does not accept writes now:" >&2
  echo "    cd $DIR && docker compose restart loki   (same container, nothing lost)" >&2; exit 1; fi
docker cp "$C:/loki" "$DBK" && chmod 700 "$DBK"
echo "    copied → $DBK  ($(du -sh "$DBK" | cut -f1)); delete it after a few days when everything looks fine"

echo "--- 4. new compose, recreate loki only"
cat "$NEW" > "$F"            # keeps owner/permissions of the original
( cd "$DIR" && docker compose up -d --no-deps --force-recreate --timeout 120 loki ) 2>&1 | sed 's/^/    /'

echo "--- 5. waiting for /ready"
ok=; for i in $(seq 1 150); do curl -sf "$L/ready" >/dev/null && { ok=1; break; }; sleep 2; done
if [ -z "$ok" ]; then
  echo "!!! Loki not ready after 5 min — restoring the old compose and recreating as before" >&2
  ( cd "$DIR" && docker compose logs --tail 30 loki ) >&2 || true
  cp -a "$BK" "$F"; ( cd "$DIR" && docker compose up -d --no-deps --force-recreate loki ); exit 1
fi
echo "    ready after $(( $(date +%s) - S )) s in total"
NC=$(docker ps -q --filter label=com.docker.compose.project=grafana-loki --filter label=com.docker.compose.service=loki | head -1)
echo "    mounts: $(docker inspect -f '{{range .Mounts}}{{.Destination}}←{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}  {{end}}' "$NC")"
echo "    log limit: $(docker inspect -f '{{json .HostConfig.LogConfig.Config}}' "$NC")"
sleep 20
AFTER=$(count "$T" || echo -1)
if [ "$AFTER" -ge "$BEFORE" ]; then echo "--- check window: before $BEFORE, after $AFTER → OK, nothing lost"
else echo "!!! check window: before $BEFORE, after $AFTER → $((BEFORE-AFTER)) lines not found — tell Claude/ssa, do not retry" >&2; fi
echo "    old Docker log file: $(ls "$LP" >/dev/null 2>&1 && echo 'STILL THERE' || echo deleted)"
held=$( { find /proc -mindepth 3 -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname "*$(basename "$LP")*(deleted)" 2>/dev/null || true; } | wc -l)
if [ "$held" -gt 0 ]; then
  fb=$(docker ps --format '{{.Names}}' | grep -m1 filebeat || true)
  fbdir=$([ -n "$fb" ] && docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$fb" || true)
  echo "--- the deleted log is still held open by $held fd(s) (filebeat${fb:+: $fb}) → space comes back after:"
  echo "    cd ${fbdir:-<filebeat compose dir>} && docker compose restart filebeat"
else echo "--- the old log's space is free"; fi
echo "==> done. Rollback (gives back the old setup, not the old log): cp $BK $F && cd $DIR && docker compose up -d --no-deps --force-recreate loki"
