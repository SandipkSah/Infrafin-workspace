#!/usr/bin/env bash
# One-time cutover: sameersbn/gitlab + standalone registry:2  -->  Omnibus gitlab-ce
#
# This is the exact procedure rehearsed and verified locally (nxreh project):
#   - backup/restore of the GitLab application data via the official rake tasks
#   - secrets carried over so existing encrypted columns stay readable
#   - container registry images migrated by a direct filesystem copy, since
#     gitlab-backup does NOT capture them when the registry runs as a separate
#     container (confirmed: the backup only tars a local path inside the GitLab
#     app container, which is empty in this split topology)
#   - registry metadata database populated from that filesystem data via
#     `gitlab-ctl registry-database import`, which is what makes the automated
#     container-expiration (cleanup) policy actually delete tags instead of
#     silently no-op'ing the way it did against registry:2
#
# Prerequisites before running this script:
#   1. The new gitlab-ce container is already up and has completed its FIRST
#      `gitlab-ctl reconfigure` (i.e. `docker compose up -d gitlab-ce` has been
#      run once and the container reports healthy). This script reconfigures
#      it two more times as part of the secrets swap.
#   2. The new container's docker-compose.yaml bind-mounts a host directory to
#      /var/opt/gitlab/backups (see gitlab-ce-docker-compose.yaml ./backups).
#      This script uses that same host directory to hand the backup tarball
#      from the old container to the new one.
#   3. Both the old GitLab container and the old registry container are
#      reachable from this host via `docker exec`/`docker cp` (i.e. this runs
#      on the same Docker host as both, or against the same remote context).
#
# Usage:
#   OLD_GITLAB_CONTAINER=gitlab \
#   OLD_REGISTRY_CONTAINER=registry \
#   NEW_GITLAB_CONTAINER=gitlab-ce \
#   HOST_BACKUP_DIR=./backups \
#   ./migrate-to-gitlab-ce.sh

set -euo pipefail

OLD_GITLAB_CONTAINER="${OLD_GITLAB_CONTAINER:-gitlab}"
OLD_REGISTRY_CONTAINER="${OLD_REGISTRY_CONTAINER:-registry}"
NEW_GITLAB_CONTAINER="${NEW_GITLAB_CONTAINER:-gitlab-ce}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-./backups}"
NEW_REGISTRY_STORAGE_PATH="${NEW_REGISTRY_STORAGE_PATH:-/var/opt/gitlab/gitlab-rails/shared/registry}"
OLD_REGISTRY_STORAGE_PATH="${OLD_REGISTRY_STORAGE_PATH:-/registry}"
OLD_SECRETS_FILE="${OLD_SECRETS_FILE:-/home/git/gitlab/config/secrets.yml}"
WORKDIR="$(mktemp -d)"

log() { printf '\n==> %s\n' "$1"; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

mkdir -p "$HOST_BACKUP_DIR"

log "Step 1/9: ensure old GitLab's backup prerequisites exist"
docker exec -u git "$OLD_GITLAB_CONTAINER" mkdir -p /home/git/data/shared/ci_catalog_bundles

log "Step 2/9: create a fresh backup on the old GitLab instance"
docker exec "$OLD_GITLAB_CONTAINER" bundle exec rake gitlab:backup:create RAILS_ENV=production CRON=1
BACKUP_FILE="$(docker exec "$OLD_GITLAB_CONTAINER" sh -c 'ls -t /home/git/data/backups/*_gitlab_backup.tar | head -1')"
BACKUP_BASENAME="$(basename "$BACKUP_FILE")"
BACKUP_ID="${BACKUP_BASENAME%_gitlab_backup.tar}"
echo "Backup created: $BACKUP_BASENAME (BACKUP=$BACKUP_ID)"

log "Step 3/9: copy the backup tarball to the new container's backup directory"
docker cp "$OLD_GITLAB_CONTAINER:$BACKUP_FILE" "$HOST_BACKUP_DIR/$BACKUP_BASENAME"

log "Step 4/9: extract secrets from the old instance (needed to decrypt existing encrypted columns)"
docker exec "$OLD_GITLAB_CONTAINER" cat "$OLD_SECRETS_FILE" > "$WORKDIR/secrets.yml"
docker exec "$OLD_GITLAB_CONTAINER" /opt/gitlab/embedded/bin/ruby -e "
require 'yaml'
s = YAML.load_file('$OLD_SECRETS_FILE')['production']
require 'json'
puts JSON.generate(s)
" 2>/dev/null > "$WORKDIR/old_secrets.json" || \
docker exec "$OLD_GITLAB_CONTAINER" ruby -e "
require 'yaml'; require 'json'
s = YAML.load_file('$OLD_SECRETS_FILE')['production']
puts JSON.generate(s)
" > "$WORKDIR/old_secrets.json"

log "Step 5/9: patch the new instance's gitlab-secrets.json with the old secrets"
docker cp "$WORKDIR/old_secrets.json" "$NEW_GITLAB_CONTAINER:/tmp/old_secrets.json"
cat > "$WORKDIR/patch-secrets.rb" <<'RUBY'
require 'json'
old = JSON.parse(File.read('/tmp/old_secrets.json'))
path = '/etc/gitlab/gitlab-secrets.json'
secrets = JSON.parse(File.read(path))
rails = secrets['gitlab_rails']

rails['secret_key_base'] = old['secret_key_base'] if old['secret_key_base']
rails['db_key_base']     = old['db_key_base']     if old['db_key_base']
rails['otp_key_base']    = old['otp_key_base']    if old['otp_key_base']
rails['encrypted_settings_key_base'] = old['encrypted_settings_key_base']
rails['openid_connect_signing_key']  = old['openid_connect_signing_key'] if old['openid_connect_signing_key']

if old['active_record_encryption_primary_key']
  rails['active_record_encryption_primary_key'] = Array(old['active_record_encryption_primary_key'])
end
if old['active_record_encryption_deterministic_key']
  rails['active_record_encryption_deterministic_key'] = Array(old['active_record_encryption_deterministic_key'])
end
if old['active_record_encryption_key_derivation_salt']
  rails['active_record_encryption_key_derivation_salt'] = old['active_record_encryption_key_derivation_salt']
end

File.write(path, JSON.pretty_generate(secrets))
File.delete('/tmp/old_secrets.json')
puts 'secrets patched'
RUBY
docker cp "$WORKDIR/patch-secrets.rb" "$NEW_GITLAB_CONTAINER:/tmp/patch-secrets.rb"
docker exec "$NEW_GITLAB_CONTAINER" /opt/gitlab/embedded/bin/ruby /tmp/patch-secrets.rb
docker exec "$NEW_GITLAB_CONTAINER" chmod 600 /etc/gitlab/gitlab-secrets.json
docker exec "$NEW_GITLAB_CONTAINER" rm -f /tmp/patch-secrets.rb
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl reconfigure

log "Step 6/9: stop puma and sidekiq on the new instance before restoring"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl stop sidekiq
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl stop puma || docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl kill puma

log "Step 7/9: restore the application data backup"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-backup restore BACKUP="$BACKUP_ID" force=yes
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl reconfigure
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl restart

log "Step 8/9: migrate container registry images (not covered by gitlab-backup in this topology)"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl stop registry
docker cp "$OLD_REGISTRY_CONTAINER:$OLD_REGISTRY_STORAGE_PATH/docker" "$WORKDIR/registry-docker"
docker cp "$WORKDIR/registry-docker" "$NEW_GITLAB_CONTAINER:$NEW_REGISTRY_STORAGE_PATH/docker-imported"
docker exec "$NEW_GITLAB_CONTAINER" sh -c "
  mkdir -p '$NEW_REGISTRY_STORAGE_PATH/docker/registry/v2/repositories'
  mkdir -p '$NEW_REGISTRY_STORAGE_PATH/docker/registry/v2/blobs'
  cp -a '$NEW_REGISTRY_STORAGE_PATH/docker-imported/registry/v2/repositories/.' '$NEW_REGISTRY_STORAGE_PATH/docker/registry/v2/repositories/'
  cp -a '$NEW_REGISTRY_STORAGE_PATH/docker-imported/registry/v2/blobs/.' '$NEW_REGISTRY_STORAGE_PATH/docker/registry/v2/blobs/'
  rm -rf '$NEW_REGISTRY_STORAGE_PATH/docker-imported'
  chown -R registry:registry '$NEW_REGISTRY_STORAGE_PATH/docker'
"

log "Step 9/9: import the migrated images into the registry's metadata database"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-ctl registry-database import

log "Verification"
echo "Users:"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-rails runner "User.all.each { |u| puts \"  #{u.username} #{u.email}\" }"
echo "Projects:"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-rails runner "Project.all.each { |p| puts \"  #{p.full_path}\" }"
echo "Container repositories and tags:"
docker exec "$NEW_GITLAB_CONTAINER" gitlab-rails runner "
ContainerRepository.all.each do |r|
  puts \"  #{r.path}: #{r.tags.map(&:name).join(', ')}\"
  puts \"    supports_gitlab_api?: #{ContainerRegistry::GitlabApiClient.supports_gitlab_api?}\"
end
"

log "Done. Review the output above: confirm the user/project/tag counts match the old instance before decommissioning it."
