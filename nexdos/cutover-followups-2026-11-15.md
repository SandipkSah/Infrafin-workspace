# Cutover follow-ups — 2026-11-15

## Open: mystery DNS alias on gitlab-ce

**Symptom**: `gitlab-ce`'s container has its own `VIRTUAL_HOST` value (e.g.
`git-staging.nexdos.de` while it was staging, now `git.nexdos.de` since the
real cutover) showing up as a literal entry in its own `DNSNames` list on
`proxy_network` — separate from (and persisting even after clearing) the
normal `.Aliases` field via `docker network disconnect`/`connect`.

**Effect**: any other container on `proxy_network` (notably the shared
`gitlab-runner` container, serving all 8 production CI runner identities)
resolves the hostname straight to `gitlab-ce`'s own container IP instead of
through `nginx-proxy` — and since `gitlab-ce` only listens on plain port 80
internally (TLS terminates at `nginx-proxy`), this causes
`connection refused` on 443 for any internal (non-browser) client. External
browser traffic is unaffected since it goes through public DNS -> the
host's public IP -> nginx-proxy, a completely different path.

**Current workaround (applied, working)**: recreated `gitlab-runner` with a
durable `--add-host git.nexdos.de:172.19.0.26` (nginx-proxy's IP at the
time) baked into the container, bypassing the bad resolution entirely.
Same technique was used earlier for the staging throwaway runner.

**Why this is only a workaround, not a fix**:
- Doesn't address the root cause — something is still injecting the alias.
- Tied to nginx-proxy's *current* IP, which has already drifted once
  (172.19.0.4 → 172.19.0.26) between checks. If nginx-proxy restarts again
  and gets reassigned, this override goes stale and the symptom would
  return.

**Ruled out as the source** (checked during investigation):
- `docker-compose.yaml` for gitlab-ce — no `aliases:` key anywhere.
- `clone-from-prod.sh`, `import-prod-env.sh`, `backup.sh` — no
  `network connect`/`alias` references.
- Crontabs — none for any user on the host.
- `/etc/cron.d`, `/etc/systemd/system` — no matches.
- Host-wide pattern — checked 4 other `VIRTUAL_HOST`-fronted containers
  (`nexdos-nginx-1`, `authentik-server-1`, `healthchecks`, `uptime-kuma`);
  none show a stray self-alias. This is specific to `gitlab-ce`.
- `nginx-proxy-gen` — stock `nginxproxy/docker-gen:latest` image, standard
  entrypoint/command, no custom logic that would do this.

**Key clue that rules out "stale leftover record"**: the alias's value
dynamically tracks whatever `VIRTUAL_HOST` currently is — it was
`git-staging.nexdos.de` while this was the test copy, and changed to
`git.nexdos.de` right after the cutover's `.env` switch. Something is
actively reading `VIRTUAL_HOST` and applying it as a network alias on
every `gitlab-ce` (re)creation — not a one-time manual leftover.

**Next steps to actually root-cause it**:
1. Watch `docker events` live during the *next* `gitlab-ce` recreation (a
   future refresh, or any `docker compose up -d`) to catch whatever issues
   the `network connect --alias` call in real time.
2. Ask Hendrik directly — he built the original clone-from-prod.sh/test-copy
   tooling and may have added something deliberately (for a reason not yet
   understood) without documenting it.

**Lower-priority structural improvement regardless of root cause**: give
`nginx-proxy` a static IP on `proxy_network` (Compose
`networks.<net>.ipv4_address`) so any future `--add-host`-style override
never goes stale again from an IP reassignment.

## To verify tomorrow: first real cleanup-policy run

All 3 enabled policies (`idp/nexdos_app`, `homepage/nexdos`,
`dagster/user-code/pipeline`) show `next_run_at: 2026-11-16 13:00:04` —
this will be the first time these policies actually execute for real
(SANITIZE=false kept them enabled, and this is Omnibus now, so
`supports_gitlab_api?` is true and the digest-based delete path works).
Check after that time that tags were actually deleted as expected (keep_n
most recent + name_regex_keep protecting main/master/stable/latest/
release-*/vX.Y.Z), and that registry disk usage drops accordingly — no
manual GC needed on this instance, the metadata DB handles it online.

## Other minor cleanup noted during cutover

- Leftover `staging-test-runner` (`glrtr-ZB`) entry still in the shared
  `gitlab-runner` container's `config.toml`, now orphaned (its Ci::Runner
  DB row was wiped by the full staging refresh, and its TLS cert for
  `git-staging.nexdos.de` reads as expired/invalid). Purely log noise,
  safe to remove from `config.toml` whenever convenient.
