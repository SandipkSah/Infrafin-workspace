#!/usr/bin/env bash
# Estimates how much space the "safe to delete" categories would free on this host.
# READ-ONLY: only measures, deletes nothing. Run as root on each host:
#   bash safe_cleanup_estimate.sh
set -u

gb() { awk -v b="${1:-0}" 'BEGIN { printf "%8.1f GB", b/1e9 }'; }
sum_find() { find "$@" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
sum_du() { du -scb "$@" 2>/dev/null | tail -1 | cut -f1; }
to_bytes() {  # "306.4MB" / "1.2GB" / "12kB" -> bytes
  awk -v v="$1" 'BEGIN { n=v+0; u=v; gsub(/[0-9.]/,"",u); u=toupper(u)
    m=(u=="KB")?1e3:(u=="MB")?1e6:(u=="GB")?1e9:(u=="TB")?1e12:1; printf "%.0f", n*m }'
}

total=0
row() { printf '%-48s %s   %s\n' "$1" "$(gb "$2")" "$3"; total=$((total + ${2:-0})); }

echo "Host: $(hostname)   $(date '+%F %T')"
df -h / /home /data 2>/dev/null | awk 'NR==1 || !seen[$0]++'
echo
printf '%-48s %11s   %s\n' "Category" "Size" "What you lose"
printf '%s\n' "----------------------------------------------------------------------------------------------"

if command -v docker >/dev/null 2>&1; then
  ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
  bc=$(docker builder du 2>/dev/null | awk '/^Reclaimable:/ {print $2}')
  row "Docker build cache (reclaimable)" "$(to_bytes "${bc:-0}")" "slower next build"
  dang=0; for s in $(docker images -f dangling=true --format '{{.Size}}'); do dang=$((dang + $(to_bytes "$s"))); done
  row "Dangling images (<none>), upper bound" "$dang" "nothing"
  row "Container logs > 100 MB" "$(sum_find "$ROOT/containers" -name '*-json.log' -size +100M)" "old container log history"
  echo "  largest container logs:"
  find "$ROOT/containers" -name '*-json.log' -size +1G -printf '%s %h\n' 2>/dev/null | sort -rn | head -5 |
    while read -r s d; do printf '    %s  %s\n' "$(gb "$s")" "$(docker inspect -f '{{.Name}}' "$(basename "$d")" 2>/dev/null || basename "$d")"; done
else
  echo "(docker not available)"
fi

j=$(du -sb /var/log/journal 2>/dev/null | cut -f1); j=${j:-0}
row "systemd journal above 1 GB" "$(( j > 1000000000 ? j - 1000000000 : 0 ))" "old system logs"
row "Rotated logs in /var/log (*.gz, *.1 ...)" "$(sum_find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \))" "old log archives"
row "apt package cache" "$(sum_du /var/cache/apt/archives)" "nothing (re-downloaded)"
row "pip caches (root + users)" "$(sum_du /root/.cache/pip /home/*/.cache/pip)" "nothing (re-downloaded)"
row "conda package caches (host)" "$(sum_du /opt/conda/pkgs /root/*conda*/pkgs /home/*/*conda*/pkgs /home/*/.conda/pkgs)" "nothing (re-downloaded)"

if command -v docker >/dev/null 2>&1; then
  cc=0
  for c in $(docker ps --format '{{.Names}}' | grep -i conda); do
    s=$(docker exec "$c" sh -c 'du -scb /opt/conda/pkgs /root/.cache/pip 2>/dev/null | tail -1 | cut -f1' 2>/dev/null)
    cc=$((cc + ${s:-0}))
  done
  row "conda/pip caches inside conda-* containers" "$cc" "nothing (re-downloaded)"
fi

printf '%s\n' "----------------------------------------------------------------------------------------------"
printf '%-48s %s\n' "TOTAL safe to free (estimate)" "$(gb "$total")"
