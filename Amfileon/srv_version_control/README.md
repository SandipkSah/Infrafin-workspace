# /srv version control + secret sanitization toolkit

Runbook for bringing an `/srv` tree (Docker Compose service configs) under git,
without ever committing real secrets. Written after doing this on db1/db2;
follow it end-to-end for any additional host.

## What this actually does, in one paragraph

Real config files (`docker-compose.yaml`, `redis.conf`, `users.xml`, etc.) stay
on disk exactly as they are and are **never tracked in git**. A tool scans
each one, and for anything that actually contains a secret it produces a
redacted `<file>.sanitized` twin — that twin is what gets committed instead.
A `.gitignore` file per service directory excludes the real file and lets the
`.sanitized` one through. A `docker-compose.yaml` gets one extra step first:
hardcoded `environment:` values get mechanically moved into `.env` and
replaced with `${VAR}` references, since that's a case where the file can
actually be fixed for real, not just redacted for reference. A pre-commit
hook double-checks every commit as a last-resort safety net. Nothing in this
toolkit ever prints or stages a real secret value anywhere — every script's
output is names, counts, file paths, and line numbers only.

## Prerequisites on the target host

```bash
# gitleaks (try apt first, it's not always packaged)
sudo apt update && sudo apt install -y gitleaks
# if that fails:
GITLEAKS_VERSION=$(curl -sL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" -o /tmp/gitleaks.tar.gz
tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks
sudo mv /tmp/gitleaks /usr/local/bin/

# trufflehog (official install script)
curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sudo sh -s -- -b /usr/local/bin

# detect-secrets (pre-commit hook only, not used by sanitize_service_files.py) --
# pipx keeps it isolated from system Python; installs the CLI globally
sudo apt install -y pipx && pipx ensurepath
pipx install detect-secrets
# if pipx isn't available: pip3 install --user detect-secrets

which gitleaks trufflehog detect-secrets   # confirm all three resolve
```

Gitleaks and trufflehog are used as **detectors only** — never for verification. The tooling
always passes `--no-verification`/`--redact` so nothing ever makes a live API
call with a found credential or prints the credential itself.

## Directory layout this toolkit expects

```
~/srv_version_control/
  scripts/
    sanitize_service_files.py   # the main tool
    run_all.sh                  # runs it across every service dir
    apply_service.sh            # copies generated output into the real tree
  env-variables/
    <service>/                  # staging output per service, one per run
      docker-compose.yaml.sanitized
      <other-file>.sanitized
      .env.additions
      .env.example.additions
      .gitignore
    _reports/                   # run_all.sh's per-service + summary logs
```

Nothing under `env-variables/` is precious — it's fully regeneratable by
re-running the tool. Safe to `rm -rf` and start over at any time.

## Step 0: get the scripts onto the new host

From your Mac (adjust the host alias):

```bash
ssh ssa@<host> 'mkdir -p ~/srv_version_control/scripts ~/srv_version_control/env-variables'
scp sanitize_service_files.py run_all.sh apply_service.sh pre-commit ssa@<host>:~/srv_version_control/
ssh ssa@<host> '
  mv ~/srv_version_control/sanitize_service_files.py ~/srv_version_control/scripts/
  mv ~/srv_version_control/run_all.sh ~/srv_version_control/scripts/
  mv ~/srv_version_control/apply_service.sh ~/srv_version_control/scripts/
  mv ~/srv_version_control/pre-commit ~/srv_version_control/pre-commit-hook
  chmod +x ~/srv_version_control/scripts/*.sh ~/srv_version_control/pre-commit-hook
'
```

## Step 1: figure out the real scope

Before running anything, check what's actually under the parent of the
service directory (e.g. `/srv/`, not just `/srv/docker/`) — there may be
sibling directories that have nothing to do with this repo:

```bash
ls -la /srv/
```

Decide: does the repo root need to be the parent (`/srv/`), scoped down to
just the service directory (e.g. `docker/`) via `.gitignore`? That's exactly
what db1/db2 needed (`cron/`, `docker-replicated/`, `glusterfs/` also live
under `/srv/` and are out of scope). Adjust the `.gitignore` template
(further down) accordingly — the `/*` + `!/docker/` idiom is how that's done.

Also identify, by asking whoever knows the host, or by direct evidence
(permission-denied `.env`, obviously live production role):
- **Stale/duplicate/abandoned service directories** (`*-old`, `*-test`,
  `*-failed` naming, or just known-dead by context) — candidates to `rm`
  eventually, not worth spending review time on now.
- **Directories with their own nested `.git`** (`ls -la <dir>/.git`) — these
  are separate repos (e.g. a customized clone of an upstream project),
  managed with their own `git add/commit` inside that directory, and must be
  excluded from this repo entirely (they'd otherwise be treated as broken
  embedded repos/gitlinks).
- **Live, highly sensitive services** (a production database cluster, a
  secrets manager) where a root-only `.env` is intentional, not an accident —
  these should be permanently excluded from the bulk/scripted workflow and
  handled by hand, deliberately, when actually being worked on.

## Step 2: run the sanitizer, report-only first

```bash
python3 ~/srv_version_control/scripts/sanitize_service_files.py /srv/docker/<one-service>
```

Report-only (no `--write`) never creates any file anywhere — it just prints
what it would do. Do this for one or two services by hand first to sanity
check the output makes sense for this host's config style, before running it
across everything.

Then bulk report-only across every service:

```bash
~/srv_version_control/scripts/run_all.sh
```

Edit the `SKIP` array at the top of `run_all.sh` for this host's known
non-standard/sensitive directories (see Step 1). Entries for directories that
don't exist on this host are harmless no-ops, so it's fine to keep a superset
across multiple hosts in one shared copy of the script.

## Step 3: bulk `--write`

```bash
~/srv_version_control/scripts/run_all.sh --write
```

Still nothing under `/srv/docker` is touched — this only populates
`~/srv_version_control/env-variables/<service>/` for every non-skipped
service.

## Step 4: apply, one service at a time

```bash
/home/ssa/srv_version_control/scripts/apply_service.sh <service>
```

Run as root if `/srv/docker` is root-owned (`APPLY_SERVICE_BASE_DIR` and
`APPLY_SERVICE_STAGE_ROOT` env vars exist if the defaults — `/srv/docker` and
`/home/ssa/srv_version_control/env-variables` — don't match this host).

This script is **purely additive**: it only ever creates new
`<file>.sanitized` / `.gitignore` files, asks `y/N` before each one, and
never overwrites anything that already exists. It does **not** touch
`.env`/`.env.example`, and does **not** replace the real
`docker-compose.yaml` — moving a var into a real `.env` for real, or
swapping in the `${VAR}`-substituted compose file, is a separate, deliberate
step you do by hand if and when you decide to, reviewing the diff yourself:

```bash
diff /srv/docker/<service>/docker-compose.yaml \
     ~/srv_version_control/env-variables/<service>/docker-compose.yaml.sanitized
```

Work through services in order of confidence — start with whichever ones a
scanner (not just the key-name heuristic) directly confirmed contain a real
secret; those need no manual judgment call. Then look at the ones only the
key-name layer flagged: some are real (a weak/dictionary password no scanner
catches), some are false positives (a file *path* in a tag/var whose name
happens to contain a keyword, e.g. `privateKeyFile`, `ETCD3_CACERT`) — check
the actual line before trusting either assumption.

## Step 5: initialize the repo

```bash
cd /srv   # or wherever Step 1 decided the root should be
git init
mkdir -p .githooks
cp ~ssa/srv_version_control/pre-commit-hook .githooks/pre-commit
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
cp <reviewed .gitignore> .gitignore
```

## Step 6: dry run before ever committing

```bash
git add -A
.githooks/pre-commit
```

This stages everything the `.gitignore` currently allows and runs the same
checks a real commit would, without committing. Expect it to find real
things the first time — that's the point of doing this before, not after.

**Gotcha #1**: `.gitignore` does not support trailing inline comments.
`pattern    # comment` is parsed as one literal pattern (which then matches
nothing) — comments must be on their own line above the pattern.

**Gotcha #2**: after you `apply_service.sh` a service and its new
per-directory `.gitignore` starts excluding a file that was already staged in
an earlier `git add -A`, re-running `git add -A` does **not** retroactively
drop it — ignore rules only apply to files git doesn't know about yet. Fix:

```bash
git rm -r --cached . -f -q
git add -A
```

This only clears the index (bookkeeping), never touches any real file, and
is always safe to run again before the first commit. Verify with:

```bash
git check-ignore -v <path>   # should now print the matching rule
```

**Gotcha #3**: `detect-secrets scan` silently returns zero results for an
**absolute** `--source` path, even with `--all-files` — undocumented, found by
testing. Only a path relative to the current directory works. The pre-commit
hook already handles this (`cd`s into its scan tmpdir and passes `.`), but
worth knowing if you ever invoke it directly.

**Gotcha #4**: a YAML block scalar (`KEY: |`, e.g. Spilo's `SPILO_CONFIGURATION`
or GitLab's `GITLAB_OMNIBUS_CONFIG`) is deliberately **excluded from the
generic redaction pass entirely**, not just from structural `${VAR}`
extraction. A scanner can misattribute a finding inside such a block to the
block's *key* line instead of the actual line the secret is on (observed with
both trufflehog and detect-secrets) — blindly redacting whatever text got
reported there corrupts the key while the real secret, elsewhere in the
block, stays fully exposed and looks "handled." So instead: the tool never
claims a compose file is safe if it has one of these blocks (see the
`pg-cluster-instance-2` precedent — its `SPILO_CONFIGURATION` had to be read
and confirmed clean by hand, since it holds no secrets in this repo, but a
different service's equivalent block might). If the file needed no other
changes, no `.sanitized` is generated at all and the real file is still
listed as needing `.gitignore` — meaning **it drops out of git entirely until
someone manually reviews that block and decides how to handle it**. If the
file needed other changes too, the resulting `.sanitized` still contains that
block completely untouched — the tool prints a loud warning either way; don't
skip reading it.

Repeat Step 4 → dry run → fix false positives → dry run, service by service,
until `.githooks/pre-commit` reports nothing left (or only things you've
deliberately decided to bypass with `git commit --no-verify` — check first,
every time).

## Step 7: first commit

```bash
git status   # read it, don't skip this
git commit -m "..."
```

## Reference: known false-positive shapes (don't blindly trust either signal)

- A key name containing `PRIVATE_KEY`/`CERT`/`ACCESS_KEY` etc. whose *value*
  is a file path (`/certs/ca.crt`), not embedded key material — common in
  ClickHouse/etcd/Keeper XML and YAML configs. The real material lives in a
  separately-excluded `.key`/`.pem` file.
- An nginx template referencing an `Authorization` header directive by name,
  not embedding a literal credential.
- A weak/dictionary-word password (`postgres`, `admin`, `hunter2`) — gitleaks
  and trufflehog are both entropy-based and can miss these entirely; only the
  key-name layer catches them. Don't assume "the scanner didn't confirm it,
  so it's fine."
- A test script's intentionally-wrong credential used to test failure
  handling (e.g. `PGPASSWORD=wrong-password` in an acceptance test) — harmless,
  but will still show up and doesn't need action.

## Reference: things this toolkit deliberately never does

- Never prints a secret value to stdout/stderr, in any mode, from any script.
- Never writes to the real service directory except the two additive things
  `apply_service.sh` creates (new `.sanitized`/`.gitignore` files).
- Never runs a scanner in verification mode (no live API calls with a found
  credential, ever — always `--no-verification`).
- Never assumes a `${VAR}`/`$VAR` reference or the literal word `REDACTED` is
  itself a new secret to flag (both are deliberately excluded from every
  detection pass — otherwise a properly sanitized file would re-trigger
  itself forever).
