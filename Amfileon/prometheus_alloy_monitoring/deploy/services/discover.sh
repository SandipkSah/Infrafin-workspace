#!/usr/bin/env bash
# Runs ON db1 / db2 / prod3, by a person (sudo). READ-ONLY: changes nothing, prints no secret.
# Tells Claude what it cannot see as ssa: the Docker networks of the ClickHouse/GitLab containers,
# where their config overrides are mounted, and whether metrics are already switched on.
#
#   scp deploy/services/discover.sh db1:   then   ssh -t db1 'bash ~/discover.sh'   → paste the output
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

echo "== $(hostname) $(date -u +%FT%TZ) · docker compose $(docker compose version --short 2>/dev/null)"
for c in $(docker ps -a --format '{{.Names}}' | grep -E '\.(ch|keeper)\.amf$|^gitlab-ee$|^redis' | sort); do
  echo
  echo "## $c"
  docker inspect -f 'image:    {{.Config.Image}}
state:    {{.State.Status}}
project:  {{index .Config.Labels "com.docker.compose.project.working_dir"}}
networks: {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}
mounts:   {{range .Mounts}}{{.Destination}} <= {{.Source}}{{if not .RW}} (ro){{end}};  {{end}}' "$c"
  # variable NAMES only (values never leave docker inspect)
  echo "env names: $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | cut -d= -f1 | grep -v -E '^(PATH|HOME|HOSTNAME|TZ|LANG|LC_.*)$' | tr '\n' ' ')"
  [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || continue
  case "$c" in
    *.ch.amf|*.keeper.amf)
      for d in /etc/clickhouse-server /etc/clickhouse-keeper; do
        docker exec "$c" test -d "$d" 2>/dev/null || continue
        echo "files in $d: $(docker exec "$c" find "$d" -maxdepth 2 -type f 2>/dev/null | sed "s#^$d/##" | sort | tr '\n' ' ')"
        echo "<prometheus> already in: $(docker exec "$c" grep -rl '<prometheus>' "$d" 2>/dev/null | tr '\n' ' ')"
      done
      ;;
    gitlab-ee)
      # only monitoring-related settings (no secrets among these keys)
      echo "gitlab.rb monitoring settings:"
      docker exec "$c" grep -n -E "^[[:space:]]*(prometheus_monitoring|prometheus\[|gitlab_exporter\[|puma\['exporter|sidekiq\['(metrics|listen|exporter)|gitlab_workhorse\['prometheus|gitlab_rails\['monitoring_whitelist)" /etc/gitlab/gitlab.rb 2>/dev/null | sed 's/^/  /' || true
      echo "GITLAB_OMNIBUS_CONFIG monitoring settings:"
      docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | sed -n 's/^GITLAB_OMNIBUS_CONFIG=//p' \
        | tr ';' '\n' | grep -E "prometheus|exporter|metrics|monitoring_whitelist|listen_addr" | sed 's/^/  /' || true
      echo "running services: $(docker exec "$c" gitlab-ctl status 2>/dev/null | sed -n 's/^run: \([^:]*\):.*/\1/p' | tr '\n' ' ')"
      ;;
  esac
done
