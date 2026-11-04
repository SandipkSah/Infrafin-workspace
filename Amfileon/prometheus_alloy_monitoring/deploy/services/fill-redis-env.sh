#!/usr/bin/env bash
# Runs ON the server, by a person (sudo). Staged by stage.sh as ~/fill-redis-env.sh + ~/redis-list.
#
#   ssh -t db1 'bash ~/fill-redis-env.sh'
#
# Writes /srv/docker/alloy/redis.env (root:root, 600): REDIS_PASSWORD_<NAME>=… for every Redis
# container in ~/redis-list, so Alloy's redis exporters can log in. Each password is taken from
# the container's own settings (REDIS_PASSWORD / REDIS_ARGS / command line / its .conf files),
# checked with AUTH + PING (plain, then TLS, then TLS with the instance's client certificate) and
# NEVER printed — the output is names, ports, TLS settings/file paths and ok/failed only.
# Read-only for Redis: no restart, no config change. Safe to run again.
set -euo pipefail
LIST=${1:-$HOME/redis-list}
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$LIST"
OUT=/srv/docker/alloy/redis.env
[ -d /srv/docker/alloy ] || { echo "/srv/docker/alloy missing — install Alloy first" >&2; exit 1; }
umask 077
NEW=$(mktemp)
trap 'rm -f "$NEW"' EXIT

unquote() { sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }

# Collects the settings that matter for connecting, from (in this order) the command line,
# REDIS_ARGS and every .conf file the container uses. Only these keys are read; the password
# (requirepass) stays in a variable and is never printed.
KEYS="requirepass port tls-port tls-ca-cert-file tls-cert-file tls-key-file tls-auth-clients"
settings() {   # $1 container → "key value" lines
  local c=$1 args env conf
  args=$(docker inspect -f '{{.Path}} {{join .Args " "}}' "$c")
  env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")
  { printf '%s\n' "$args"; printf '%s\n' "$env" | sed -n 's/^REDIS_ARGS=//p'; } \
    | awk -v keys="$KEYS" 'BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want["--" k[i]] = k[i] }
                           { for (i = 1; i < NF; i++) if ($i in want) print want[$i], $(i + 1) }'
  printf '%s\n' "$env" | sed -n 's/^REDIS_PASSWORD=/requirepass /p'
  for conf in $(printf '%s\n' "$args" | tr ' ' '\n' | grep '\.conf$') \
              $(docker exec "$c" sh -c 'ls /etc/redis/*.conf /redis-stack.conf 2>/dev/null' || true); do
    docker exec "$c" awk -v keys="$KEYS" 'BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
                                          ($1 in want) && NF >= 2 { print $1, $2 }' "$conf" 2>/dev/null || true
  done
}
get() { printf '%s\n' "$SETTINGS" | awk -v k="$1" '$1 == k { print $2; exit }' | unquote; }

try() {   # $1 container, $2 port, $3.. redis-cli TLS options → last reply line
  local c=$1 port=$2; shift 2
  if [ -n "$PW" ]; then   # AUTH over stdin, so it never shows up in `ps`
    printf 'AUTH %s\nPING\n' "$PW" | docker exec -i "$c" redis-cli -p "$port" "$@" 2>&1 | tail -1 || true
  else
    docker exec "$c" redis-cli -p "$port" "$@" PING 2>&1 | tail -1 || true
  fi
}

ok=0; failed=0
while read -r name port var; do
  case "$name" in ''|'#'*) continue ;; esac
  if ! docker inspect "$name" >/dev/null 2>&1 || [ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]; then
    echo "  $name: not running — skipped"; failed=$((failed + 1)); continue
  fi
  SETTINGS=$(settings "$name")
  PW=$(get requirepass)
  case "$PW" in *"'"*) echo "  $name: password contains a quote — add it to $OUT by hand"; failed=$((failed + 1)); continue ;; esac
  tport=$(get tls-port); ca=$(get tls-ca-cert-file); cert=$(get tls-cert-file); key=$(get tls-key-file)
  [ -n "$ca" ] || { docker exec "$name" test -f /etc/redis/CA.pem 2>/dev/null && ca=/etc/redis/CA.pem; } || true
  echo "  $name: password $([ -n "$PW" ] && echo found || echo "not set") · port=$(get port) tls-port=${tport:--} tls-auth-clients=$(get tls-auth-clients) ca=${ca:--} cert=${cert:--}"
  mode=""; errs=""
  r=$(try "$name" "$port"); [ "$r" = PONG ] && mode=plain || errs="plain: $r"
  if [ -z "$mode" ] && [ -n "$ca" ]; then
    r=$(try "$name" "${tport:-$port}" --tls --cacert "$ca"); [ "$r" = PONG ] && mode="tls (CA only)" || errs="$errs | tls: $r"
  fi
  if [ -z "$mode" ] && [ -n "$ca" ] && [ -n "$cert" ] && [ -n "$key" ]; then
    r=$(try "$name" "${tport:-$port}" --tls --cacert "$ca" --cert "$cert" --key "$key")
    [ "$r" = PONG ] && mode="tls + client certificate" || errs="$errs | tls+cert: $r"
  fi
  if [ -n "$mode" ]; then
    printf "%s='%s'\n" "$var" "$PW" >> "$NEW"
    echo "      ok via $mode"
    ok=$((ok + 1))
  else
    echo "      FAILED — $errs"
    failed=$((failed + 1))
  fi
done < "$LIST"

# keep values for instances not in this run (e.g. added by hand)
if [ -f "$OUT" ]; then
  grep -v -F -f <(cut -s -d"'" -f1 "$NEW") "$OUT" >> "$NEW" 2>/dev/null || true
fi
install -m 600 -o root -g root "$NEW" "$OUT"
echo "==> $OUT: $ok ok, $failed failed/skipped ($(grep -c '' "$OUT") entries)"
