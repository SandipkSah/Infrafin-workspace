# nexdos Registry — Current State & Online-GC Migration Notes

Working notes for whether/how to get the nexdos container registry onto a metadata-database /
online-GC setup, analogous to what was done for Amfileon. Captures what's confirmed on the live
host plus the actual `docker-compose.yaml`, so this doesn't need re-deriving later.

---

## 1. Why this isn't a drop-in repeat of the Amfileon process

Amfileon runs **Omnibus GitLab** (`gitlab/gitlab-ce`) — one container, `gitlab.rb`/`GITLAB_OMNIBUS_CONFIG`,
`gitlab-ctl`, and a **bundled registry process that is GitLab's own fork** of the Docker/Distribution
registry (`gitlab-org/container-registry`). That fork is what supports the metadata database
(`registry['database']`) and `gitlab-ctl registry-database migrate/import`.

nexdos runs **`sameersbn/gitlab`**, a from-source (non-Omnibus) build, paired with a **separate,
plain `registry:2`** container (upstream `docker/distribution`, unforked). Confirmed on-host:

```
docker exec gitlab which gitlab-ctl        → not found
docker exec gitlab ls /etc/gitlab/gitlab.rb → No such file or directory
docker exec registry registry --version    → registry github.com/docker/distribution 2.8.3
docker exec registry registry database --help → Error: unknown command "database"
```

**Conclusion: the metadata-database / online-GC feature is not available at all with the current
`registry:2` image — this is a binary capability gap, not a config gap.** No amount of
`GITLAB_OMNIBUS_CONFIG`/env-var tweaking on either container can add it, because the plain
distribution binary has no code path that knows how to read/write metadata from Postgres.

---

## 2. What `GITLAB_OMNIBUS_CONFIG` actually does on this image

The `gitlab` service sets `GITLAB_OMNIBUS_CONFIG` with Ruby/Omnibus-style directives, but only for
**GitLab KAS** (`gitlab_kas['enable']`, socket paths, `gitlab_kas_external_url`). Real config —
hostname, ports, HTTPS, DB, SMTP, LDAP, registry — is all done the standard **sameersbn way**, via
flat `GITLAB_*`/`DB_*`/`LDAP_*`/`SMTP_*` env vars. Since there's no `gitlab-ctl`/`gitlab.rb`, this
image's entrypoint must have a **custom, narrow parser** that only understands the `gitlab_kas[...]`
keys (to bolt on KAS support, which stock sameersbn lacks) — it is not a general Omnibus
interpreter. Other commented-out directives in the same block (`external_url`, `nginx[...]`) are
dead — they're not being applied (real HTTP config comes from `GITLAB_HOST`/`GITLAB_HTTPS`/etc.).

**Implication:** don't expect `registry['database'] = {...}` dropped into `GITLAB_OMNIBUS_CONFIG` to
do anything on this image, even setting the binary-capability issue aside.

---

## 3. Current registry auth/network wiring (from the real compose file)

```yaml
gitlab:
  environment:
    - GITLAB_REGISTRY_ENABLED=true
    - GITLAB_REGISTRY_HOST=registry.nexdos.de
    - GITLAB_REGISTRY_PORT=443
    - GITLAB_REGISTRY_API_URL=http://registry:5000       # internal, container-to-container
    - GITLAB_REGISTRY_KEY_PATH=/certs/registry.key        # private key, GitLab signs JWTs with this
    - GITLAB_REGISTRY_ISSUER=gitlab-issuer
    - GITLAB_REGISTRY_GENERATE_INTERNAL_CERTIFICATES=true # sameersbn auto-generates the keypair
  volumes:
    - certs-data:/certs        # shared with the registry container

registry:
  image: registry:2             # plain docker/distribution 2.8.3, confirmed no `database` subcommand
  volumes:
    - registry-data:/registry
    - certs-data:/certs         # shares the same volume → gets the public cert GitLab generated
  environment:
    - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/registry
    - REGISTRY_STORAGE_DELETE_ENABLED=true
    - REGISTRY_AUTH_TOKEN_REALM=https://git.nexdos.de/jwt/auth
    - REGISTRY_AUTH_TOKEN_SERVICE=container_registry
    - REGISTRY_AUTH_TOKEN_ISSUER=gitlab-issuer             # must match GITLAB_REGISTRY_ISSUER
    - REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE=/certs/registry.crt  # public cert, validates GitLab's JWTs
  ports:
    - "5000"                    # published to a random host port (seen earlier as 32782->5000)
```

**Auth mechanism:** `GITLAB_REGISTRY_GENERATE_INTERNAL_CERTIFICATES=true` means sameersbn generates
its own JWT signing keypair on the shared `certs-data` volume (`registry.key` private / `registry.crt`
public). GitLab signs tokens with the private key; the registry validates them against the public
cert via `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE`. Standard docker-token-auth spec — this same mechanism
is what a GitLab-fork registry image would also need to honor, so it should carry over to Option A
below without re-issuing certs, as long as the new image is pointed at the same `/certs` volume and
the same issuer/service/realm values.

**Correction to an earlier read:** the standalone `registry_config.yaml` on disk in `~/gitlab/` (no
`auth:` block, `rootdirectory: /var/lib/registry`) is **not actually mounted** — that compose line is
commented out (`#      - ./registry_config.yaml:/etc/docker/registry/config.yml`). The real,
active config is 100% the `REGISTRY_*` env vars above (rootdirectory `/registry`, not
`/var/lib/registry`). Treat `registry_config.yaml` as a stale reference file, not the live config.

**Storage backend:** plain filesystem (`/registry`) — no OSS/Swift driver, so the deprecation in
upstream issue [#1141](https://gitlab.com/gitlab-org/container-registry/-/issues/1141) doesn't apply.

**Checked sameersbn's own docs/issues for a v2→v3 JWT gotcha — real, but doesn't block this plan.**
sameersbn's [container_registry.md](https://github.com/sameersbn/docker-gitlab/blob/master/docs/container_registry.md)
warns: "Docker Registry v3 is currently not compatible with the JWT tokens signed by GitLab... uses
`registry:2` to avoid issues." Root cause, per [issue #3198](https://github.com/sameersbn/docker-gitlab/issues/3198):
plain upstream Distribution v3 dropped trusting `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE` alone and now
wants `REGISTRY_AUTH_TOKEN_JWKS` instead. **This is about the vanilla community `registry:3.0`
release, not GitLab's fork** — GitLab's own current standalone config docs still show
`rootcertbundle` as the auth key for their fork (versioned `v3.x.x-gitlab` but not carrying this
breaking change). So the existing `REGISTRY_AUTH_TOKEN_ROOTCERTBUNDLE=/certs/registry.crt` setup
should still be correct for the `gitlab-container-registry` image — no JWKS needed — but confirm
`docker login`/push/pull on the throwaway test copy before trusting this on real data.

**Exposure note (unrelated to the DB question, worth a separate look):** the `registry` service
publishes port 5000 directly (`ports: ["5000"]`) in addition to being reachable via
`VIRTUAL_HOST=registry.nexdos.de` on the shared `proxy_network`. Since auth is enforced by the
registry itself (`REGISTRY_AUTH_TOKEN_*` env vars are present and correctly wired), a random
high host port alone isn't a bypass of auth — but it does mean the registry's `/v2/` endpoint is
reachable pre-TLS/pre-proxy on that port. Worth confirming host firewall rules restrict that port
to trusted networks only.

---

## 4. Options considered

| Option | What it is | Effort | Notes |
|---|---|---|---|
| **A — swap only the `registry` image** | Replace `registry:2` with a GitLab container-registry fork build (e.g. `registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:v3.15.0-gitlab`), add a `database:` block, provision a Postgres DB/user, run `migrate`/`import` directly on the new binary (no `gitlab-ctl` wrapper — this isn't Omnibus) | Moderate — roughly a day, same shape as the Amfileon `gitlab-ce2` test-then-cutover exercise | GitLab's own team calls this close to a "drop-in" (config/storage compatible per [#1557](https://gitlab.com/gitlab-org/container-registry/-/issues/1557)), but that issue is itself an **open, unresolved doc request** — no official runbook exists yet. Real operators have done this on plain docker-compose ([GitLab forum thread](https://forum.gitlab.com/t/container-registry-metadata-database-migration-on-docker-installation/111263)), hand-creating the `registry` Postgres role/DB themselves since the docs don't cover non-Omnibus. That same thread confirms a GitLab 18.3 regression caused **data loss** for people who misconfigured this — back up before touching anything real. |
| **B — migrate whole instance to Omnibus `gitlab/gitlab-ce`** | Reinstall as Omnibus, restore a `gitlab-backup` into it | Large, multi-day, high risk | Needs matching GitLab version on both sides, hand-carrying secrets (`GITLAB_SECRETS_DB_KEY_BASE`/`SECRET_KEY_BASE`/`OTP_KEY_BASE` → Omnibus's own secrets file), re-doing LDAP/SMTP/KAS/proxy config from scratch (KAS ironically gets *easier* under real Omnibus — natively supported, no custom parser needed). Far more downtime/risk than the actual goal (online GC) warrants. |
| **C — keep `registry:2`, use its native offline GC** | `docker exec registry registry garbage-collect --dry-run /etc/docker/registry/config.yml` (dry-run first) then without `--dry-run`, on a schedule/maintenance window | Low — no new container, no migration | No online GC; must accept a stop-writes-or-accept-missed-mid-run-pushes caveat during each run. Cheapest, but doesn't meet the "online GC" goal. |

**Working conclusion so far:** Option A is the right-sized move for the stated goal (online GC) —
contained to the `registry` service, doesn't touch the `gitlab` app container's sameersbn quirks,
and the auth wiring (§3) should transfer without re-issuing certs. Option B is disproportionate to
the goal. Option C is the fallback if A's testing surfaces a blocker.

---

## 5. Open items before committing to Option A

- [ ] Pick a `gitlab-org/build/cng/gitlab-container-registry` tag matching the GitLab version this
      sameersbn build corresponds to (18.11.x) — confirm token-auth compatibility isn't affected by
      version skew between GitLab app and registry-fork versions.
- [ ] Decide DB placement: point at a new `registry`/`registry_database` role on the existing
      `gitlab-postgresql` (sameersbn/postgresql:14) container, or stand up a dedicated Postgres —
      mirrors the Approach A vs B choice from the Amfileon runbook. Given `sameersbn/postgresql`'s
      own env-var-driven user/DB creation model, adding a second DB/user to it needs to be done by
      hand (`CREATE USER`/`CREATE DATABASE`) — same gap the forum thread hit.
  - [ ] Confirm the picked registry-fork image's expected Postgres config shape (host/port/user/
      password/dbname/sslmode) — likely still `database:` block in `config.yml`, not env vars.
- [ ] Build a throwaway copy of this stack first (same spirit as the Amfileon `gitlab-ce2` test) —
      seed a few repos/tags, run migrate+import, confirm `docker login`/push/pull still work against
      the existing `certs-data` keypair before touching the real `registry.nexdos.de` data.
- [ ] Back up `registry-data` volume + `gitlab-postgresql`'s data before any real attempt (mirrors
      the "back up first" rule from the Amfileon runbook — the 18.3 data-loss regression makes this
      non-negotiable).
- [ ] After cutover: retire/never run `registry garbage-collect` (offline GC) again — same rule as
      Amfileon, it deletes live data once the metadata DB is authoritative.

---

## 6. Sources

- [Document how to move from the Docker/Distribution registry to the GitLab container registry (#1557)](https://gitlab.com/gitlab-org/container-registry/-/issues/1557) — open request, no official doc yet; "drop-in" claim + storage-driver caveats.
- [Deprecate: container registry support for storage Drivers OSS and Swift (#1141)](https://gitlab.com/gitlab-org/container-registry/-/issues/1141) — not applicable, nexdos uses filesystem storage.
- [Container registry metadata database: migration on docker installation — GitLab Forum](https://forum.gitlab.com/t/container-registry-metadata-database-migration-on-docker-installation/111263) — real docker-compose precedent, DB-provisioning workaround, 18.3 data-loss warning.
- [Migration of legacy container registry to registry metadata database — GitLab Forum](https://forum.gitlab.com/t/migration-of-legacy-container-registry-to-registry-metadata-database/130880)
- [GitLab container registry administration](https://docs.gitlab.com/administration/packages/container_registry/) — standalone image reference (`registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:vX.Y.Z-gitlab`).
- [Container registry metadata database](https://docs.gitlab.com/administration/packages/container_registry_metadata_database/) — Omnibus-centric, but general requirements (Postgres 12+, keep object storage, never run offline GC after import) still apply.
- Amfileon reference docs (same repo, `../gitlab-registry-config-reference.md`, `../registry-runbook.md`, `../registry-migration-test-plan.md`).
