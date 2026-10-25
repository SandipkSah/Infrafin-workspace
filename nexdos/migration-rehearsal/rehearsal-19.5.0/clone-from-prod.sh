#!/usr/bin/env bash
# Populates the gitlab-ce container with a copy of production nexdos GitLab.
#
# Based on ../migration-rehearsal/migrate-to-gitlab-ce.sh, with the changes production
# needs and the rehearsal didn't hit:
#   - prod backup runs as the git user (running it as root leaves root-owned files in
#     prod's data dir that can break its nightly backup)
#   - backup tarball chowned to git inside gitlab-ce (Omnibus refuses otherwise on Linux)
#   - registry copied ONCE, volume to volume via a throwaway container (the rehearsal
#     copied twice through a host temp dir), after checking the disk has room for it
#   - registry explicitly started again after the import
#   - with SANITIZE=true (test copy), restored data is sanitized BEFORE sidekiq first runs
#     on it: cleanup policies, webhooks, integrations, push mirrors and pipeline schedules
#     all disabled, so the copy can't fire events at real systems. Use SANITIZE=false for
#     the real migration.
#   - SSH host keys are NOT copied: fine for a test copy. For the real migration (same
#     hostname/port as prod) copy /home/git/data/ssh/ssh_host_* to /etc/gitlab/ first.
#
# Production is only read from, except (USE_EXISTING_BACKUP=false only): a backup tarball
# is created in its backup dir (removed again at the end) and the empty ci_catalog_bundles
# dir gitlab:backup needs. With USE_EXISTING_BACKUP=true the newest nightly backup is
# copied out instead and production is not modified at all.
# For the real migration, stop traffic to prod before running this - anything pushed
# after the backup / registry copy is lost.
#
# Prerequisites:
#   1. docker compose up -d   and wait until `docker ps` shows the container healthy
#      (its first reconfigure must have run on the EMPTY registry volume)
#   2. enough free disk for a full copy of the prod registry (checked in step 0)
#
# Usage (on the nexdos host, as root, from this directory): ./clone-from-prod.sh

set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

PROD="$PROD_GITLAB_CONTAINER"
TARGET="$GITLAB_CONTAINER_NAME"
REGISTRY_PATH=/var/opt/gitlab/gitlab-rails/shared/registry
WORKDIR="$(mktemp -d)"

log() { printf '\n==> %s\n' "$1"; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$BACKUP_DIR"

log "Step 0/10: sanity checks"
# Prod's image tag can be `latest`, so compare the real versions inside both containers.
prod_version="$(docker exec "$PROD" cat /home/git/gitlab/VERSION | tr -d '[:space:]')"
target_version="$(docker exec "$TARGET" cat /opt/gitlab/embedded/service/gitlab-rails/VERSION | tr -d '[:space:]')"
echo "prod: $prod_version   gitlab-ce: $target_version"
[[ "$prod_version" == "$target_version" ]] || {
  echo "Version mismatch - set GITLAB_CE_VERSION in .env to match production." >&2; exit 1; }
if [[ "${SKIP_REGISTRY:-false}" == "true" ]]; then
  echo "SKIP_REGISTRY=true: registry images will NOT be copied (projects keep their registry entries, without images)"
else
  registry_kb="$(docker run --rm -v "$PROD_REGISTRY_VOLUME:/from:ro" alpine du -sk /from | cut -f1)"
  # Measured from inside the target volume: that's the disk the copy lands on.
  free_kb="$(docker run --rm -v "${REGISTRY_VOLUME:-gitlab-ce-registry}:/to" alpine df -Pk /to | awk 'NR==2 {print $4}')"
  echo "prod registry: $(( registry_kb / 1024 / 1024 ))GB   free on docker disk: $(( free_kb / 1024 / 1024 ))GB"
  # Keep a 100GB margin for the backup tarball, the import and everything else on this host.
  (( free_kb > registry_kb + 100 * 1024 * 1024 )) || {
    echo "Not enough disk for the registry copy - clean up old images first, or set SKIP_REGISTRY=true." >&2; exit 1; }
fi

LOCAL_BACKUP=""
if [[ "${USE_EXISTING_BACKUP:-false}" == "true" ]]; then
  # A tarball already copied into BACKUP_DIR by hand wins; otherwise take prod's newest.
  LOCAL_BACKUP="$(ls -t "$BACKUP_DIR"/*_gitlab_backup.tar 2>/dev/null | head -1 || true)"
  if [[ -n "$LOCAL_BACKUP" ]]; then
    log "Steps 1-2/10: use backup already in $BACKUP_DIR (production is not touched)"
    BACKUP_BASENAME="$(basename "$LOCAL_BACKUP")"
    ls -l "$LOCAL_BACKUP"
  else
    log "Steps 1-2/10: use prod's newest existing backup (production is not modified)"
    BACKUP_FILE="$(docker exec "$PROD" sh -c 'ls -t /home/git/data/backups/*_gitlab_backup.tar | head -1')"
    BACKUP_BASENAME="$(basename "$BACKUP_FILE")"
    docker exec "$PROD" ls -l --time-style=+%F_%H:%M "$BACKUP_FILE"
  fi
  # Restore only works into the exact version the backup was made with (it's in the name).
  [[ "$BACKUP_BASENAME" == *"_${prod_version}_gitlab_backup.tar" ]] || {
    echo "Backup $BACKUP_BASENAME is not from GitLab $prod_version - use a backup made on $prod_version." >&2; exit 1; }
else
  log "Step 1/10: ensure prod's backup prerequisites exist"
  docker exec -u git "$PROD" mkdir -p /home/git/data/shared/ci_catalog_bundles

  log "Step 2/10: create a fresh backup on production (live, non-disruptive)"
  docker exec -u git -e HOME=/home/git -w /home/git/gitlab "$PROD" \
    bundle exec rake gitlab:backup:create RAILS_ENV=production CRON=1
  BACKUP_FILE="$(docker exec "$PROD" sh -c 'ls -t /home/git/data/backups/*_gitlab_backup.tar | head -1')"
  BACKUP_BASENAME="$(basename "$BACKUP_FILE")"
fi
BACKUP_ID="${BACKUP_BASENAME%_gitlab_backup.tar}"
echo "Backup: $BACKUP_BASENAME (BACKUP=$BACKUP_ID)"

log "Step 3/10: hand the tarball to gitlab-ce"
[[ -n "$LOCAL_BACKUP" ]] || docker cp "$PROD:$BACKUP_FILE" "$BACKUP_DIR/$BACKUP_BASENAME"
docker exec "$TARGET" chown git:git "/var/opt/gitlab/backups/$BACKUP_BASENAME"
[[ "${USE_EXISTING_BACKUP:-false}" == "true" ]] || docker exec "$PROD" rm -f "$BACKUP_FILE"

log "Step 4/10: extract prod secrets (needed to decrypt encrypted columns)"
docker exec "$PROD" ruby -e "
require 'yaml'; require 'json'
s = YAML.load_file('$PROD_SECRETS_FILE')['production']
puts JSON.generate(s)
" > "$WORKDIR/old_secrets.json"

log "Step 5/10: patch gitlab-ce's gitlab-secrets.json with prod's secrets"
docker cp "$WORKDIR/old_secrets.json" "$TARGET:/tmp/old_secrets.json"
cat > "$WORKDIR/patch-secrets.rb" <<'RUBY'
require 'json'
old = JSON.parse(File.read('/tmp/old_secrets.json'))
path = '/etc/gitlab/gitlab-secrets.json'
secrets = JSON.parse(File.read(path))
rails = secrets['gitlab_rails']

%w[secret_key_base db_key_base otp_key_base encrypted_settings_key_base
   openid_connect_signing_key active_record_encryption_key_derivation_salt].each do |k|
  rails[k] = old[k] if old[k]
end
%w[active_record_encryption_primary_key active_record_encryption_deterministic_key].each do |k|
  rails[k] = Array(old[k]) if old[k]
end

File.write(path, JSON.pretty_generate(secrets))
File.delete('/tmp/old_secrets.json')
puts 'secrets patched'
RUBY
docker cp "$WORKDIR/patch-secrets.rb" "$TARGET:/tmp/patch-secrets.rb"
docker exec "$TARGET" /opt/gitlab/embedded/bin/ruby /tmp/patch-secrets.rb
docker exec "$TARGET" chmod 600 /etc/gitlab/gitlab-secrets.json
docker exec "$TARGET" rm -f /tmp/patch-secrets.rb
docker exec "$TARGET" gitlab-ctl reconfigure

log "Step 6/10: stop puma and sidekiq before restoring"
docker exec "$TARGET" gitlab-ctl stop sidekiq
docker exec "$TARGET" gitlab-ctl stop puma || docker exec "$TARGET" gitlab-ctl kill puma

log "Step 7/10: restore the application data backup"
docker exec "$TARGET" gitlab-backup restore BACKUP="$BACKUP_ID" force=yes
docker exec "$TARGET" rm -f "/var/opt/gitlab/backups/$BACKUP_BASENAME"

log "Step 8/10: sanitize restored data before sidekiq ever runs on it (SANITIZE=$SANITIZE)"
[[ "$SANITIZE" == "true" ]] && docker exec "$TARGET" gitlab-rails runner "
puts \"cleanup policies disabled: #{ContainerExpirationPolicy.where(enabled: true).update_all(enabled: false)}\"
puts \"pipeline schedules paused: #{Ci::PipelineSchedule.where(active: true).update_all(active: false)}\"
puts \"push mirrors disabled:     #{RemoteMirror.where(enabled: true).update_all(enabled: false)}\"
puts \"integrations disabled:     #{Integration.where(active: true).update_all(active: false)}\"
hooks = WebHook.count; WebHook.find_each(&:destroy)
puts \"webhooks removed:          #{hooks}\"
System::BroadcastMessage.create!(
  message: 'TEST COPY of git.nexdos.de - changes here are not kept and do not reach production.',
  starts_at: Time.current, ends_at: 1.year.from_now)
"
docker exec "$TARGET" gitlab-ctl reconfigure
docker exec "$TARGET" gitlab-ctl restart

if [[ "${SKIP_REGISTRY:-false}" == "true" ]]; then
  log "Step 9/10: registry copy skipped (SKIP_REGISTRY=true) - re-run with it off once there's disk space"
else
  log "Step 9/10: copy registry data from prod's volume into gitlab-ce's and import it"
  docker exec "$TARGET" gitlab-ctl stop registry
  docker run --rm \
    -v "$PROD_REGISTRY_VOLUME:/from:ro" \
    -v "${REGISTRY_VOLUME:-gitlab-ce-registry}:/to" \
    alpine sh -c '
      for d in repositories blobs; do
        mkdir -p /to/docker/registry/v2/$d
        cp -a /from/docker/registry/v2/$d/. /to/docker/registry/v2/$d/
      done
    '
  docker exec "$TARGET" chown -R registry:registry "$REGISTRY_PATH/docker"
  docker exec "$TARGET" gitlab-ctl registry-database migrate up
  docker exec "$TARGET" gitlab-ctl registry-database import
  docker exec "$TARGET" gitlab-ctl start registry
  docker exec "$TARGET" gitlab-ctl status registry
fi

log "Step 10/10: verification"
docker exec "$TARGET" gitlab-rails runner "
puts \"users:                 #{User.count}\"
puts \"projects:              #{Project.count}\"
puts \"container repos:       #{ContainerRepository.count}\"
puts \"supports_gitlab_api?:  #{ContainerRegistry::GitlabApiClient.supports_gitlab_api?}\"
r = ContainerRepository.first
puts \"sample: #{r.path} -> #{(r.tags.first(5).map(&:name).join(', ') rescue 'no tags (registry not copied?)')}\" if r
"
echo "Compare with prod:"
docker exec -u git -e HOME=/home/git -w /home/git/gitlab "$PROD" bundle exec rails runner -e production \
  "puts \"users: #{User.count}  projects: #{Project.count}  container repos: #{ContainerRepository.count}\""

log "Done. gitlab-ce: https://$GITLAB_HOST  (registry: $GITLAB_REGISTRY_HOST, ssh port $GITLAB_SSH_PORT)"
