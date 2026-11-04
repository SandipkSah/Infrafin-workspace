#!/bin/sh
# Small, steady traffic so every dashboard panel has something to show. Runs in its own container.
#   ch      ClickHouse: replicated table, inserts + selects, an occasional failing query
#   redis   both Redis servers: SET/GET/INCR, a few misses
#   gitlab  GitLab: sign-in page, API (401), health, a 404
set -u
case "$1" in
  ch)
    q() { clickhouse client -h db1.production.ch.amf -u load --password load -q "$1"; }
    until q "SELECT 1" >/dev/null 2>&1; do sleep 3; done
    q "CREATE TABLE IF NOT EXISTS events (ts DateTime, k UInt32, v Float64)
       ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}') ORDER BY (k, ts)"
    i=0
    while true; do
      q "INSERT INTO events SELECT now(), rand() % 1000, randCanonical() FROM numbers(20000)"
      q "SELECT k, avg(v) FROM events GROUP BY k ORDER BY k LIMIT 5 FORMAT Null"
      i=$((i + 1)); [ $((i % 10)) -eq 0 ] && q "SELECT no_such_column FROM events" >/dev/null 2>&1
      sleep 2
    done ;;
  redis)
    while true; do
      for n in $(seq 1 50); do
        printf 'SET key:%s %s\nGET key:%s\nGET missing:%s\nINCR counter\n' "$n" "$n" "$n" "$n"
      done | REDISCLI_AUTH="$REDIS_PROD_PW" redis-cli --tls --cacert /certs/ca.pem -h production.redis.amf -p 46379 >/dev/null
      for n in $(seq 1 30); do
        printf 'SET s:%s x EX 60\nGET s:%s\nGET nope:%s\n' "$n" "$n" "$n"
      done | redis-cli -h redis-staging -p 26379 >/dev/null
      sleep 1
    done ;;
  gitlab)
    until wget -q -O /dev/null http://gitlab-ee/-/readiness 2>/dev/null || wget -q -O /dev/null http://gitlab-ee/users/sign_in; do sleep 10; done
    while true; do
      for p in /users/sign_in /api/v4/projects /api/v4/version /explore /does-not-exist; do
        wget -q -O /dev/null "http://gitlab-ee$p" 2>/dev/null
      done
      sleep 2
    done ;;
esac
