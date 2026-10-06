#!/usr/bin/env bash
# Collects the "Pending measurements" for db1-storage-overview.md.
# READ-ONLY: no deletes, no config changes. Run on db1 as root:
#   bash collect_pending.sh 2>&1 | tee /tmp/db1-pending.txt
set -u

CH=db1.production.ch.amf
MINIO=minio-s3-1
GITLAB=gitlab-ee
LOG_IDS='8aa4b454|9cdd930c|d7b9d0e5|1a1f7ef2|2223f5bb|0454e25d|b8d16c8e|84aef30a|539ab944'

section() { printf '\n========== %s ==========\n' "$1"; }

section "1. Containers behind the large logs"
docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' \
  | grep -E "^($LOG_IDS)" | cut -c1-12,65-
echo "-- log config"
for id in $(docker ps -aq --no-trunc | grep -E "^($LOG_IDS)"); do
  docker inspect -f '{{.Name}}  {{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}' "$id"
done

section "2. Last lines of the 603G log (first 300 chars each)"
tail -n 15 /data/docker-data-root/containers/8aa4b454*/8aa4b454*-json.log | cut -c1-300

section "3. MinIO per-bucket usage (scanner metrics)"
docker exec "$MINIO" sh -c '
export MC_HOST_local="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000"
timeout 120 mc admin prometheus metrics local bucket 2>&1 \
  | grep -E "^minio_bucket_usage_(total_bytes|object_total|version_total|deletemarker_total)\{" \
  | sort -t" " -k2 -g
echo "-- versioning per bucket"
for b in $(timeout 60 mc ls local/ | awk "{print \$NF}"); do
  printf "%s  %s\n" "$b" "$(mc version info local/$b 2>/dev/null | tail -1)"
done
echo "-- lifecycle rules"
for b in $(timeout 60 mc ls local/ | awk "{print \$NF}"); do
  echo "## $b"; mc ilm rule ls local/$b 2>&1 | tail -n +2
done'

section "4. ClickHouse: who queries the old-version databases (90 d)"
docker exec -i "$CH" clickhouse-client -q "
SELECT arrayJoin(databases) AS db, query_kind, user, max(event_time) AS last, count() AS n
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date >= today() - 90
  AND db IN ('refinitiv_minute_bars_v6','refinitiv_indicative_v3','refinitiv_preopen_minute_bars_v6',
             'factor_model','factor_model_v3','factor_model_v4','factor_model_v7','factor_model_v8')
GROUP BY db, query_kind, user ORDER BY db, last DESC FORMAT PrettyCompact"

section "5. ClickHouse: largest tables in minute_bars_v7 (OPTIMIZE target)"
docker exec -i "$CH" clickhouse-client -q "
SELECT table, formatReadableSize(sum(bytes_on_disk)) size,
       formatReadableSize(max(bytes_on_disk)) largest_part, count() parts
FROM system.parts WHERE active AND database = 'refinitiv_minute_bars_v7'
GROUP BY table ORDER BY sum(bytes_on_disk) DESC LIMIT 10 FORMAT PrettyCompact"
echo "-- running merges / mutations"
docker exec -i "$CH" clickhouse-client -q "
SELECT database, table, round(elapsed) sec, round(progress, 2) progress,
       formatReadableSize(total_size_bytes_compressed) size
FROM system.merges FORMAT PrettyCompact"

section "6. GitLab: existing cleanup policies + image pin"
docker exec "$GITLAB" gitlab-rails runner '
puts "projects with registry: #{Project.joins(:container_repositories).distinct.count}"
puts "policies enabled:       #{ContainerExpirationPolicy.where(enabled: true).count}"
ContainerExpirationPolicy.where(enabled: true).each { |p|
  puts "  #{p.project.full_path}: keep_n=#{p.keep_n} older_than=#{p.older_than} delete=#{p.name_regex} keep=#{p.name_regex_keep} cadence=#{p.cadence}" }'
grep -n "image:" /srv/docker/gitlab-ee/docker-compose*.y*ml 2>/dev/null
docker image inspect gitlab/gitlab-ce:latest -f '{{.Id}} {{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null

section "7. Images running on db1 (for registry keep-rules)"
docker ps --format '{{.Image}}' | sort -u

section "8. Owners of unclear volumes"
for v in clickhouse_data clickhouse-external_data clickhouse_external_data \
         3951ee252b3df968042ec500a1ad378f197d47ffd7be365d8c3c4d4fd60c5a0a \
         be446e69d3ac3f74f2a58da3f973295e4756d22e54c145bb777bb1011f8914a6 \
         sentry-postgres uptime-kuma_uptime-kuma gitlab-ee_gitlab-data; do
  printf '%-70s %s\n' "$v" "$(docker ps -a --filter volume=$v --format '{{.Names}} ({{.Status}})' | tr '\n' ' ')"
done

section "9. Fill rate from Prometheus (GB/day, negative = shrinking free space)"
P=$(docker ps --format '{{.Names}}' | grep -i prometheus | head -1)
echo "prometheus container: ${P:-none}"
[ -n "$P" ] && docker exec "$P" wget -qO- \
  'http://localhost:9090/api/v1/query?query=deriv(node_filesystem_avail_bytes{mountpoint=~".*data"}[7d])*86400/1e9'
echo

section "10. Filesystem type and reserved blocks"
df -hT /data
df -i /data
tune2fs -l /dev/md0 2>/dev/null | grep -iE "reserved block count|block count|block size" || echo "not ext4 (or tune2fs unavailable)"

section "done"
