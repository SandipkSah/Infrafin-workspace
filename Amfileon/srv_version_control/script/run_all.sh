#!/usr/bin/env bash
# Runs sanitize_service_files.py across every service dir under /srv/docker.
# Never touches /srv/docker itself -- that's true in report-only mode AND with
# --write, since --write only ever creates new files under
# ~/srv_version_control/env-variables/<service>/ (docker-compose.yaml.sanitized,
# .env.additions, .env.example.additions, and <filename>.sanitized for every
# other top-level file). Applying any of it onto the real service directory is
# a separate, manual, per-service step you do yourself -- this script never
# does that, in either mode. Never prints secret values.
#
# Usage:
#   run_all.sh            report-only (default)
#   run_all.sh --write     also generates the .sanitized/.additions files for every service
set -uo pipefail

WRITE_FLAG=""
if [[ "${1:-}" == "--write" ]]; then
  WRITE_FLAG="--write"
fi

SCRIPT_DIR="$HOME/srv_version_control/scripts"
BASE_DIR="/srv/docker"
LOG_DIR="$HOME/srv_version_control/env-variables/_reports"
mkdir -p "$LOG_DIR"

# Known non-standard dirs, skipped in this bulk pass (handle separately). Shared
# across hosts (db1, db2, ...) -- an entry that doesn't exist on a given host is
# simply never matched, so it's harmless to keep the full list on every host.
#   dockprom/, zulip/, netbox-docker/,        - own nested .git repos (upstream clones),
#   elastdocker/                                not folded into this one
#   gittlab-runner/                          - stale typo duplicate of gitlab-runner/, no compose file
#   pg-cluster-instance-1/, pg-cluster-instance-2/  - live production Postgres HA cluster (db1, db2
#                                               respectively); .env is root-only by design.
#   healthchecks/, nessie/ (db1)              - also root-only .env; treated the same as the
#                                               Postgres cluster: live/sensitive enough to keep out
#                                               of the bulk/scripted pass.
#   vault/, vault2/, infisical/ (db1),        - dedicated secrets-management services; deliberately
#   vault-agent-example/ (cpu1)                 excluded from the bulk pass, same reasoning as the
#                                               Postgres cluster -- handle by hand, not blind-scanned.
#                                               vault-agent-example/ holds a live vault-token despite
#                                               the "example" name; treat it as real until proven otherwise.
#   conda/ (cpu1)                             - dev/testing sandbox with heavy, messy clutter (8
#                                               different .env variants, a vault-token, many stray
#                                               backup/old compose files) -- needs a deliberate by-hand
#                                               pass, not a blind bulk run.
#   gitlab-ee-failed/, grafana-loki-old/,     - stale/dead duplicates (see naming), not worth
#   sentry-old/, sentrytest/, infisical_test/   review time; kept out of git, never deleted.
#   archived/ (gpu1)                          - holding pen of retired services (postgres,
#                                               trading/trading-production/trading-test,
#                                               gitlab-runner subdirs) -- not structured as a
#                                               normal single-compose-file service directory,
#                                               and not live, so not worth scanning.
#   All of the above: handle by hand, as root, when actually working on them.
SKIP=(dockprom zulip gittlab-runner pg-cluster-instance-1 pg-cluster-instance-2 healthchecks nessie \
      netbox-docker elastdocker vault vault2 infisical vault-agent-example conda archived \
      gitlab-ee-failed grafana-loki-old sentry-old sentrytest infisical_test)

should_skip() {
  local name="$1"
  if [[ ${#SKIP[@]} -gt 0 ]]; then
    for s in "${SKIP[@]}"; do
      [[ "$name" == "$s" ]] && return 0
    done
  fi
  return 1
}

summary="$LOG_DIR/summary.txt"
: > "$summary"

for dir in "$BASE_DIR"/*/; do
  name="$(basename "$dir")"

  if should_skip "$name"; then
    printf '%-30s SKIPPED (known non-standard, see script header)\n' "$name" | tee -a "$summary"
    continue
  fi

  report_file="$LOG_DIR/${name}.report.txt"
  if python3 "$SCRIPT_DIR/sanitize_service_files.py" "$dir" $WRITE_FLAG > "$report_file" 2>&1; then
    n_vars=$(grep -oE 'vars that would move to \.env: [0-9]+' "$report_file" | grep -oE '[0-9]+' || true)
    n_conflicts=$(grep -c '^  CONFLICTS' "$report_file" || true)
    n_multiline=$(grep -c '^  SKIPPED --' "$report_file" || true)
    # Per-directory .gitignore entries print as bare "    filename" (single
    # token, no internal spaces) -- distinct from "    diff a b" / "    cat a >> b"
    # and "    - KEY  (tag)" lines, which do have internal spaces, so this
    # pattern doesn't pick those up too.
    n_secret_files=$(grep -cE '^    [^ ]+$' "$report_file" || true)
    printf '%-30s vars=%-4s conflicts=%-2s multiline=%-2s secret_files=%-2s  (%s)\n' \
      "$name" "${n_vars:-0}" "$n_conflicts" "$n_multiline" "$n_secret_files" "$report_file" | tee -a "$summary"
  else
    reason=$(tail -1 "$report_file")
    printf '%-30s ERROR: %s\n' "$name" "$reason" | tee -a "$summary"
  fi
done

echo
echo "Full per-service reports under: $LOG_DIR"
echo "Summary saved to: $summary"
