# gitlab-ce — nexdos GitLab on Omnibus

Replacement for the current production GitLab (`sameersbn/gitlab` + a separate `registry:2`,
in `/srv/docker/gitlab`). Runs side by side with it on the same host until cutover.

Why: GitLab's registry cleanup policies silently do nothing against plain `registry:2`
(tag-name deletes return 404, which GitLab counts as success). Omnibus bundles GitLab's own
registry with a metadata database, where cleanup policies really delete tags.

| | Old production | This instance |
|---|---|---|
| Folder | `/srv/docker/gitlab` | `/srv/docker/gitlab-ce` |
| Compose project / container | `gitlab` / `gitlab` | `gitlab-ce` / `gitlab-ce` |
| Volumes | `gitlab_*` | `gitlab-ce_config`, `gitlab-ce_logs`, `gitlab-ce_data`, `gitlab-ce-registry` |
| URL | git.nexdos.de, registry.nexdos.de | git-staging.nexdos.de, registry-staging.nexdos.de (until cutover) |
| SSH | 10022 | 20022 (until cutover) |

The two never share volumes. Only `proxy_network` (nginx-proxy + Let's Encrypt) and the
`ldap` network are shared.

All commands below run as **root** in `/srv/docker/gitlab-ce`.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | The gitlab-ce service. All values come from `.env`. |
| `.env.example` → `.env` | Settings and secrets (`.env` is never committed). |
| `import-prod-env.sh` | Fills `.env` with the live LDAP + SMTP settings and GitLab version from the production container, and adds settings `.env.example` has but `.env` lacks. Only reads production; prints no values. Safe to re-run. |
| `clone-from-prod.sh` | Restores production's data into this instance (see below). |
| `backup.sh` | Nightly backup (database, repos, … without the registry, plus `/etc/gitlab` with the secrets). For host cron after cutover. |
| `backups/` | Hand-off folder for backup tarballs (mounted as `/var/opt/gitlab/backups`). |

## First setup

```bash
cp .env.example .env && chmod 600 .env
./import-prod-env.sh            # expect "23 of 23 values set" (fewer if prod doesn't set some SMTP vars)
docker compose up -d            # wait until `docker ps --filter name=gitlab-ce` shows (healthy), ~3-5 min
```

## What `clone-from-prod.sh` does

1. Checks that production and gitlab-ce run the **same GitLab version** (a restore only works into the exact version).
2. Takes a backup (see `USE_EXISTING_BACKUP`), copies production's secrets into gitlab-ce so encrypted data
   (CI variables, 2FA, tokens) stays readable, and restores the backup.
3. With `SANITIZE=true`: disables cleanup policies, webhooks, integrations, push mirrors and pipeline schedules
   before anything runs, and shows a "TEST COPY" banner, so the copy can't act on real systems.
4. Unless `SKIP_REGISTRY=true`: copies production's registry volume into `gitlab-ce-registry` and imports it
   into the registry metadata database. Refuses to start without registry size + 100 GB free disk.
5. Prints users / projects / container repos for both instances to compare.

The backup itself never contains the registry images (on production they live in a separate container),
which is why they're copied separately.

### `.env` switches

| Variable | `true` | `false` |
|---|---|---|
| `USE_EXISTING_BACKUP` | Restore a backup already in `backups/`, else production's newest nightly (01:00). **Production is not touched.** | Create a fresh backup on production first (live, ~1 min of load; temporary file removed afterwards). Use at cutover. |
| `SKIP_REGISTRY` | Leave registry images out. | Copy + import registry images. Only into an **empty** gitlab-ce (see refresh B). |
| `SANITIZE` | Test copy (see step 3). | Real migration: everything stays active. |
| `EMAIL_ENABLED` | Sends email via the SMTP settings. **Only at cutover.** | No email at all (test copy — it must never email real users). |

`HC_PING_URL` (external monitor ping in the healthcheck) stays **empty** on the test copy; pinging production's
check from here would hide a real outage.

Run long jobs with `nohup` so an SSH disconnect doesn't kill them, and watch the log:

```bash
nohup ./clone-from-prod.sh > clone-$(date +%F-%H%M).log 2>&1 &
tail -f clone-*.log             # Ctrl-C stops watching, not the script
pgrep -af clone-from-prod.sh    # prints a line while it's still running
```

Done when the log ends with `==> Done. gitlab-ce: ...`. A difference of a few users/projects against
production is normal when restoring a nightly backup (created since 01:00).

## Refreshing to production's newest state

Every refresh overwrites everything on gitlab-ce, including changes made there (e.g. a disabled 2FA).

### A. Refresh everything except registry images (quick, ~5 min)

Database, git repos, users, issues, MRs, CI data come from a fresh production backup. Registry images stay
as they were copied; images pushed to production since then won't show up.

```bash
sed -i -e 's/^USE_EXISTING_BACKUP=true/USE_EXISTING_BACKUP=false/' \
       -e 's/^SKIP_REGISTRY=false/SKIP_REGISTRY=true/' .env
nohup ./clone-from-prod.sh > clone-$(date +%F-%H%M).log 2>&1 &
```

Use this for routine refreshes.

### B. Full refresh including the registry (~30 min)

The registry copy + import must only run into an **empty** gitlab-ce: run again into one that already has a
registry, it would leave stale images behind (the copy only adds, never deletes) and import into an
already-filled registry database. So wipe gitlab-ce and start from scratch:

```bash
docker compose down -v          # deletes ONLY gitlab-ce's volumes (gitlab-ce_*, gitlab-ce-registry), never production's gitlab_*
docker compose up -d            # fresh, empty gitlab-ce; wait until (healthy), ~3-5 min
sed -i -e 's/^USE_EXISTING_BACKUP=true/USE_EXISTING_BACKUP=false/' \
       -e 's/^SKIP_REGISTRY=true/SKIP_REGISTRY=false/' .env
nohup ./clone-from-prod.sh > clone-$(date +%F-%H%M).log 2>&1 &
```

> `docker compose down -v` is only safe **in this folder**. Never run it in `/srv/docker/gitlab` — that's production.

**Either way:**

- **Production**: `USE_EXISTING_BACKUP=false` runs a backup there for about a minute and deletes its temporary
  file afterwards. To leave production completely untouched, keep `true` and copy the newest nightly into
  `backups/` first:
  ```bash
  cp /var/lib/docker/volumes/gitlab_gitlab-data/_data/backups/*_gitlab_backup.tar backups/
  ```
- **Registry cleanup**: don't delete tags or run `registry garbage-collect` on production during a refresh B —
  a blob deleted mid-copy breaks the import.

## Logging in on the test copy

LDAP and local passwords work as on production. Security keys / passkeys (WebAuthn) don't: they're bound to
`git.nexdos.de` and browsers refuse them on another domain (`NotAllowedError`). Use the authenticator-app code
instead, a recovery code, or disable 2FA for yourself on the copy only:

```bash
docker exec gitlab-ce gitlab-rails runner 'u = User.find_by_username!("USERNAME"); u.disable_two_factor!; puts "2FA off for #{u.username}"'
```

After cutover the instance runs as `git.nexdos.de` again and security keys work as before.

## Known pre-existing issue

`gitlab-rake gitlab:doctor:secrets` reports 15 rows it can't decrypt — identically on production, so not caused
by the clone: 14 legacy OTP rows (old column; the real `User` OTP secrets decrypt fine) and one Dependency Proxy
group setting (re-enter its credentials under the group's Settings → Packages and registries).

## Moving the folder

Volume names come from `name: gitlab-ce` in the compose file, not from the folder, so the folder can move freely:

```bash
docker compose down             # NOT -v
mv <old path> <new path> && cd <new path> && docker compose up -d
```

Don't change `name:` or the `gitlab-ce-registry` volume name — that would start an empty instance.

## Cutover runbook

Already prepared and tested on the copy: SMTP settings (off until `EMAIL_ENABLED=true`), `backup.sh`,
healthcheck with optional ping, SSH host key copy (fingerprints identical to production), registry copy +
import, cleanup policies really deleting. No DNS change is needed: both instances are on the same host
behind nginx-proxy, which routes by hostname.

### Before the day

1. **Cleanup policies**: production's enabled policies come over enabled and, unlike on `registry:2`, really
   delete — their first run catches up on everything at once. None has a keep-regex today. Adjust them in
   production's UI if needed (e.g. `^(main|master|stable|latest|release-.*|v[0-9]+\.[0-9]+\.[0-9]+)$`).
2. **Monitoring ping**: note the old instance's ping URL for `HC_PING_URL`:
   `grep -o 'https://hc.nexdos.de/ping/[^ ]*' /srv/docker/gitlab/docker-compose.yml`
3. **Window**: ~1 hour of no writes (registry copy ~15 min + import ~6 min + restore/restart/checks). Announce it,
   and have someone with project access ready to test registry push/pull and a CI pipeline.

### On the day (as root)

**a. Reset gitlab-ce to empty** (registry import must go into an empty instance). Production still running:
```bash
cd /srv/docker/gitlab-ce
docker compose down -v && docker compose up -d     # wait until (healthy), ~5 min
```

**b. Stop writes to the old instance** (the container keeps running: the backup and secrets come from it):
```bash
docker exec gitlab supervisorctl stop nginx sshd puma sidekiq   # web, git over SSH, background jobs
docker stop registry                                            # no more pushes; volume stays readable
```

**c. Migrate** (fresh backup, nothing sanitized, registry included):
```bash
sed -i -e 's/^USE_EXISTING_BACKUP=.*/USE_EXISTING_BACKUP=false/' \
       -e 's/^SKIP_REGISTRY=.*/SKIP_REGISTRY=false/' \
       -e 's/^SANITIZE=.*/SANITIZE=false/' .env
nohup ./clone-from-prod.sh > cutover-$(date +%F-%H%M).log 2>&1 &
tail -f cutover-*.log                                           # until "==> Done"
```
On a version mismatch the script stops at step 0: set `GITLAB_CE_VERSION` to production's version,
`docker compose up -d`, and start again from a.

**d. Copy the SSH host keys** (again — `down -v` in step a removed the ones from the test):
```bash
docker cp gitlab:/home/git/data/ssh/. /tmp/gitlab-ssh-keys
docker cp /tmp/gitlab-ssh-keys/. gitlab-ce:/etc/gitlab/
docker exec gitlab-ce sh -c 'chmod 600 /etc/gitlab/ssh_host_*_key && chmod 644 /etc/gitlab/ssh_host_*_key.pub'
rm -rf /tmp/gitlab-ssh-keys
```

**e. Stop the old instance completely** (`stop`, not `down`: containers and volumes stay for rollback):
```bash
cd /srv/docker/gitlab && docker compose stop
```

**f. Switch gitlab-ce to production** — URLs, SSH port, email, monitoring, resources:
```bash
cd /srv/docker/gitlab-ce
sed -i -e 's/^GITLAB_HOST=.*/GITLAB_HOST=git.nexdos.de/' \
       -e 's/^GITLAB_REGISTRY_HOST=.*/GITLAB_REGISTRY_HOST=registry.nexdos.de/' \
       -e 's/^GITLAB_SSH_PORT=.*/GITLAB_SSH_PORT=10022/' \
       -e 's/^EMAIL_ENABLED=.*/EMAIL_ENABLED=true/' \
       -e 's/^PUMA_WORKER_PROCESSES=.*/PUMA_WORKER_PROCESSES=4/' \
       -e 's/^SIDEKIQ_CONCURRENCY=.*/SIDEKIQ_CONCURRENCY=20/' .env
nano .env                                                      # set HC_PING_URL to the URL from "Before the day" 2
docker compose up -d                                           # recreates with the real names, ~5 min until healthy
```
The Let's Encrypt companion issues/reuses the certificates for git.nexdos.de and registry.nexdos.de.

**g. Verify**:
- web login (LDAP; security keys / passkeys work again on the real domain)
- `git clone` / push over SSH on port 10022, no host-key warning
- `docker login registry.nexdos.de`, push + pull (someone with project access)
- a CI pipeline runs (runners point at `https://git.nexdos.de/`, same tokens — they reconnect on their own)
- a test email arrives:
  `docker exec gitlab-ce gitlab-rails runner 'Notify.test_email("you@example.com", "GitLab test", "it works").deliver_now'`

### Rollback (if g fails)

```bash
cd /srv/docker/gitlab-ce && docker compose stop
cd /srv/docker/gitlab && docker compose start      # old instance back with all processes
```
Anything written to gitlab-ce in between is lost.

### After the cutover

1. Nightly backup — root's crontab (`crontab -e`):
   `0 1 * * * /srv/docker/gitlab-ce/backup.sh >> /srv/docker/gitlab-ce/backups/backup.log 2>&1`
   Run it once by hand to check. The registry isn't in it — give the `gitlab-ce-registry` volume its own off-host backup.
2. Watch the first cleanup-policy runs (Settings → Packages and registries of each project).
3. Never run `registry garbage-collect` on the new instance — the metadata database handles cleanup online.
4. Keep the old instance's volumes ~2 weeks, then remove them (`gitlab_registry-data` alone is ~310 GB).
