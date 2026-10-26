---
name: howto_server_changes
description: Rules for any work that touches the Amfileon servers (db1, db2, cpu1, cpu2, gpu1, prod3) — access, root steps, secrets, and locking down new /srv/docker services afterwards.
---

# Making changes on the Amfileon servers

## Access — what Claude may do

- `ssh <host>` / `scp` as `ssa` (port 22022, VPN required) for **read-only inspection** and for
  **staging files in `~ssa/`**. Nothing else.
- **Never run `docker` or `sudo` on the servers.** `ssa` is not in the docker group and has no
  passwordless sudo; the user stated explicitly: *"you are not allowed to run docker without root
  permission."* A `permission denied` on the docker socket is expected — do not try to work around it.
- **prod4** is out of scope until the user has access; its host key is unknown — never accept it.

## How a change is delivered

1. Prepare everything in the repo (compose file, configs, `.env.example`, `INSTALL.md` with every
   root command clearly marked). Validate locally (`docker compose config`, `promtool`, `amtool`,
   `alloy validate`, a local rehearsal where behaviour matters).
2. Stage with scp into `~ssa/<service>-deploy/` (mode 700).
3. **The user** runs the root steps (`sudo cp -a … /srv/docker/<service>/`, `sudo docker compose up -d`).
4. Verify from outside without root (HTTPS APIs, curl) and report.

## Secrets

- Secrets live only in `.env` files (repo: git-ignored `secrets/`; server: `/srv/docker/<svc>/.env`).
  Configs reference variable names; containers turn them into files at start-up if the program
  can't read env vars itself (e.g. Prometheus `web.yml`, Alertmanager `url_file`).
- **Never read, print or echo a secret value** — generate with scripts that print nothing, pass
  values straight to the consuming command, and check only names/counts/HTTP codes.
- If a secret shows up in output anyway (e.g. an echoed sudo password in a `tee`'d log): tell the
  user immediately, recommend rotating it, and scrub it from local files.

## Lock down new services at the END of a rollout (mandatory)

During a rollout the new `/srv/docker/<service>` files are `ssa`-owned (from `cp -a` of the
staging dir) so configs can still be adjusted. **Once everything is set up and verified**, they must
match the existing services so `ssa` — and therefore Claude — can no longer edit them:

```bash
sudo chown -R root:root /srv/docker/<service>
sudo find /srv/docker/<service> -type d -exec chmod 755 {} +
sudo find /srv/docker/<service> -type f -exec chmod 644 {} +
sudo chmod 600 /srv/docker/<service>/.env    # recommended; existing services' .env are 644 — ask the user
```

Do **not** lock down mid-rollout (the user: *"that is for later once you set up everything"*), but
never finish a rollout without this step — remind the user if it hasn't been run.
