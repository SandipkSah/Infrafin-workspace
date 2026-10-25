#!/usr/bin/env bash
# Nightly backup of gitlab-ce, run from host cron (Omnibus has no built-in schedule like
# sameersbn's GITLAB_BACKUP_SCHEDULE). Enable only after cutover:
#
#   0 1 * * *  /srv/docker/gitlab-ce/backup.sh >> /srv/docker/gitlab-ce/backups/backup.log 2>&1
#
# Writes into ./backups (= /var/opt/gitlab/backups):
#   - <id>_gitlab_backup.tar  database, repos, uploads, artifacts, LFS, packages, ...
#                             SKIP=registry: the registry (~310GB) is NOT archived - it would
#                             fill the disk every night. Its data lives in the gitlab-ce-registry
#                             volume and needs its own (off-host) backup.
#   - etc/gitlab_config_*.tar /etc/gitlab incl. gitlab-secrets.json, which gitlab-backup never
#                             includes and without which the tarball can't be fully restored.
# Old tarballs are pruned by gitlab-backup after BACKUP_KEEP_TIME (.env); old config archives
# after the same number of days here.

set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

CONTAINER="$GITLAB_CONTAINER_NAME"
KEEP_DAYS=$(( ${BACKUP_KEEP_TIME:-604800} / 86400 ))

echo "==> $(date '+%F %T') gitlab-backup (SKIP=registry)"
docker exec "$CONTAINER" gitlab-backup create CRON=1 SKIP=registry

echo "==> $(date '+%F %T') /etc/gitlab (secrets + config)"
docker exec "$CONTAINER" sh -c 'mkdir -p /var/opt/gitlab/backups/etc && chmod 700 /var/opt/gitlab/backups/etc'
docker exec "$CONTAINER" gitlab-ctl backup-etc --backup-path /var/opt/gitlab/backups/etc
docker exec "$CONTAINER" find /var/opt/gitlab/backups/etc -name 'gitlab_config_*.tar' -mtime +"$KEEP_DAYS" -delete

echo "==> $(date '+%F %T') done"
docker exec "$CONTAINER" sh -c 'ls -lh /var/opt/gitlab/backups/*_gitlab_backup.tar /var/opt/gitlab/backups/etc | tail -5'
