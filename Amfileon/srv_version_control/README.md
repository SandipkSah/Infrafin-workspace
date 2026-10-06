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

# detect-secrets (used by BOTH sanitize_service_files.py as a 4th signal
# AND the pre-commit hook) --
# pipx keeps it isolated from system Python; installs the CLI globally
sudo apt install -y pipx && pipx ensurepath
pipx install detect-secrets
# if pipx isn't available: pip3 install --user detect-secrets

which gitleaks trufflehog detect-secrets   # confirm all three resolve
```

**Gotcha, found on gpu1**: a `pip install --user` (or `pipx install`) puts the
package under the INSTALLING user's own home directory
(`~/.local/lib/python3.x/site-packages/`). Symlinking the resulting
`~/.local/bin/detect-secrets` into `/usr/local/bin/` (so a second user --
typically root, since `/srv/docker/*` is usually root-owned -- can also run
the command) makes the *binary* resolve, but NOT the *package*: Python's
user-site-packages lookup is based on the EXECUTING user's home, not the
file owner's, so root running that symlinked script still raises
`ModuleNotFoundError: No module named 'detect_secrets'`. This silently
degrades `sanitize_service_files.py`'s detection to 3 signals instead of 4
whenever it's run as root (prints a `WARNING: detect-secrets exited 1
unexpectedly` and continues, which is easy to miss) -- and since the
pre-commit hook almost always runs as root too (via `git commit` on a
root-owned repo), this breaks that safety net as well, silently. Fix: give
root (or whichever user actually runs these tools) its own real install,
not just a symlink to someone else's:
```bash
curl -sS https://bootstrap.pypa.io/get-pip.py -o /root/get-pip.py
python3 /root/get-pip.py --user
/root/.local/bin/pip install --user detect-secrets
ln -sf /root/.local/bin/detect-secrets /usr/local/bin/detect-secrets
```
Verify with `detect-secrets scan --all-files <anyfile>` as that same user --
it should print JSON and exit 0, not traceback.

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
    build_env_example.py        # builds .env.example from an existing real .env (Step 8)
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

**Gotcha #5** (found on gpu1, fixed in `sanitize_service_files.py`): a
non-secret config KEY can merely *contain* a tracked keyword as a substring —
our keyword regexes have no word-boundary check before the keyword, by
design (needed to still match compound names like `SMTP_PASSWORD`). nginx's
`server_tokens off;` directive (hides the nginx version in response headers —
nothing to do with auth tokens) contains "token", so the space-assignment
keyword regex matched it and captured the value `off;`. The generic
redaction pass' cross-file known-secret propagation (meant for a genuinely
duplicated real secret, e.g. the same credential copy-pasted into several
config blocks) then treated `off;` as a confirmed secret and redacted every
other occurrence of that exact string anywhere in the file — silently
turning harmless, unrelated directives (`auth_basic`, `auth_request`,
`ssl_session_tickets`, `proxy_buffering`, `access_log`, `default`,
`ssl_prefer_server_ciphers`) into invalid nginx syntax
(`ssl_prefer_server_ciphers REDACTED;`), which would have broken the live
proxy on deploy. None of gitleaks/trufflehog/detect-secrets flagged anything
on this file — this was purely the tool's own keyword fallback. Fixed by
never treating a bare `on`/`off`/`true`/`false`/`yes`/`no` toggle value
(trailing `;`/`:`/`,` stripped first) as a secret, regardless of which
keyword matched the line it's on. Always inspect a `.sanitized` file's
*actual diff* before trusting a redaction count, especially on a file type
(`.conf`, `.tmpl`) the tool doesn't structurally understand the way it does
YAML/XML — a plausible-sounding redaction count is not the same as a correct
one.

**Gotcha #6** (found on gpu1, fixed in `sanitize_service_files.py` — the
closest call of any bug this project has hit, worth reading carefully): a
compose file can reference a variable with BARE `$VAR` syntax, no braces
(`MINIO_ROOT_PASSWORD: $MINIO_ROOT_PASSWORD`) — valid Compose substitution,
functionally identical to `${VAR}`. The tool's `_is_placeholder` helper
already recognized this form, but `extract_compose_environment`'s own
already-externalized check re-implemented a narrower one
(`val_stripped.startswith('${')`) that only matched the braced form, and
never called `_is_placeholder` at all. So a bare `$VAR` value was misread as
a 20-character hardcoded LITERAL STRING (the literal text `$MINIO_ROOT_PASSWORD`
itself, not a reference) and reported as a `CONFLICT` against the
already-externalized key of the same name already in `.env`. Comparing that
fake literal's length (20) against the real `.env` value's length (18)
looked exactly like "two different real secrets, which one is right?" —
indistinguishable from a genuine stale-value case (see `watchtower`'s real
stale `.env.example` earlier in this same session) without reading the
actual compose line itself. Manually "resolving" the supposed conflict by
copying the compose file's literal text into `.env` replaced the correct
password with the nonsense self-reference `MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD`
— caught only because `docker compose config` then warned the variable was
"not set, defaulting to blank," and the real value had to be recovered from
the *live container's own baked-in environment*
(`docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}'`),
since no file on disk held it anymore. Had the container needed a real (not
dry-run) recreate before this was caught, MinIO would have come up with a
blank root password. Fixed by having both `extract_compose_environment`
branches call `_is_placeholder` instead of their own narrower check.
**Lesson, independent of the bug fix**: before ever treating a `CONFLICT`
line's hardcoded-looking value as something to reconcile, read the actual
compose line first (safe — compose syntax, not the secret itself) and
confirm it isn't already a `$VAR`/`${VAR}` reference under a different name
or form.

Repeat Step 4 → dry run → fix false positives → dry run, service by service,
until `.githooks/pre-commit` reports nothing left (or only things you've
deliberately decided to bypass with `git commit --no-verify` — check first,
every time).

## Step 7: first commit

```bash
git status   # read it, don't skip this
git commit -m "..."
```

## Step 8 (optional, per-service, deliberate): converting to a fully working config

Everything above gets you a git-trackable `.sanitized` twin per service, with
the real file gitignored and left completely untouched — safe, but the real
file still has real secrets sitting in it forever, unconverted.

For a service you actively want to migrate further, `sanitize_service_files.py`
can instead produce a **working** replacement for the real file itself:
secrets become `${VAR}` references (not the literal word `REDACTED`), and the
real value moves to `.env` — so the file you end up tracking in git is
byte-for-byte what the service actually runs on, not just a redacted
reference copy. This works for the compose file's `environment:` block
(always did) *and* for single-line Ruby-hash-style secrets inside a block
scalar like `GITLAB_OMNIBUS_CONFIG` (`key['name'] = 'value'`, `'name' => 'value'`
— extracted the same way, not just left as `REDACTED`).

This is **per-service and deliberate** — do it for a service when you've
decided its real file should become the tracked source of truth, not as a
blanket step for everything.

### The sequence

```bash
cd /srv/docker/<service>
# 1. back up the true original -- permanent, never deleted, holds the real secrets
cp docker-compose.yaml docker-compose.yaml.pre-versioning-backup

# 2. generate fresh, then swap the extraction in
python3 ~/srv_version_control/scripts/sanitize_service_files.py /srv/docker/<service> --out-dir /tmp/<service>-check --write
cp /tmp/<service>-check/<service>/docker-compose.yaml.sanitized docker-compose.yaml

# 3. build/append .env with the real values (>> if .env already exists, cp if not)
cp /tmp/<service>-check/<service>/.env.additions .env        # first time
# cat /tmp/<service>-check/<service>/.env.additions >> .env  # .env already existed

# 4. validate -- twice. Include EVERY compose file the service actually uses
#    (docker-compose.override.yaml too, if one exists -- see gotcha below)
docker compose -f docker-compose.yaml config > /tmp/out 2>/tmp/warn; cat /tmp/warn; rm -f /tmp/out /tmp/warn
docker compose -f docker-compose.yaml up -d --dry-run

# 5. if anything shows "Recreated" instead of "Running", check whether it
#    PREDATES this change before assuming it's a bug in the conversion:
docker compose -f docker-compose.yaml.pre-versioning-backup up -d --dry-run
# same result with the untouched original? -> pre-existing (usually image
# drift -- a newer :latest was pulled locally but the container never
# recreated to use it), not caused by the conversion, safe to ignore.
# DIFFERENT result (only the converted file shows "Recreated")? -> something
# in the conversion is genuinely wrong -- investigate before moving on
# (see the two real bugs found this way, below).

# 6. update .gitignore: drop the real filename (now safe to track directly),
#    add the .pre-versioning-backup
cat > .gitignore <<'EOF'
docker-compose.yaml.pre-versioning-backup
EOF

# 7. build the git-trackable .env.example companion from the real .env
python3 ~/srv_version_control/scripts/build_env_example.py /srv/docker/<service>/.env
cat /srv/docker/<service>/.env.example.additions >> /srv/docker/<service>/.env.example
```

Files *other* than the compose file (a service's `config.toml`, `nginx.conf`,
XML configs, etc.) are **not** part of this conversion — they stay on the
existing `REDACTED`-placeholder `.sanitized` pattern; this only ever applies
to the compose file itself, since only Docker Compose resolves `${VAR}`
references at all.

### Gotchas found doing this on db2 (real bugs, not user error)

- **`docker-compose.override.yaml`**: if a service has one, *every* validation
  command needs both files (`-f docker-compose.yaml -f docker-compose.override.yaml`,
  or no explicit `-f` at all to get Compose's own auto-merge) — passing only
  the base file produces a false "Recreated" that has nothing to do with the
  actual conversion.
- **Same key name, different value, two services in one file**: Compose's
  `${VAR}` substitution is file-wide, not per-service. If two services each
  define e.g. `VIRTUAL_HOST` with genuinely different values, extracting both
  to one `.env` entry means one value silently overwrites the other — found
  via a real `minio` compose file (`minio-s3-1` and `minio-nginx`). Fixed in
  the tool: a later occurrence of an already-seen key with a different value
  now gets a disambiguated *source* name (`VIRTUAL_HOST_2`) — but the actual
  environment variable name on the left stays unchanged, since that's the
  literal name the container/nginx-proxy/docker-gen actually look for.
- **A keyword substring inside an unrelated word**: the keyword regexes have
  no word-boundary check (needed to still match compound names like
  `SMTP_PASSWORD`), so `htpasswd` (contains `passwd`) inside a volume
  bind-mount (`- ./htpasswd:/etc/nginx/htpasswd`) got misread as a "key:
  value" assignment and the mount's *target path* got corrupted into
  `REDACTED` — an actual functional break (nginx's basic-auth file fails to
  mount), not just over-redaction. Fixed by masking the specific known-safe
  whole word before keyword matching runs; extend the list in
  `_KNOWN_SAFE_TERMS_RE` if another common term collides the same way.
- **`_CERT_FILE`/`_CERT_AUTH`-named vars are usually false positives**: the
  keyword classifier flags anything containing `CERT`, but these are typically
  a file *path* or a boolean flag, not embedded key material (same shape as
  the ClickHouse/etcd reference case below). Worth a quick length-check
  before trusting the classification either way.
- **A pre-existing corruption can already be sitting in a real file,
  unrelated to anything you're doing today**: `minio`'s real
  `docker-compose.yaml` already had a bare `MINIO_ROOT_PASSWORD: REDACTED`
  literal (not even a `${VAR}` reference) *before* this conversion ever
  touched it — almost certainly a leftover from much earlier work. The real
  password only existed in the running container's baked-in environment. The
  "validate against the untouched `.pre-versioning-backup`" step (gotcha #1
  above) is exactly what surfaces this class of issue on *any* already-tracked
  service, not just ones being freshly converted — worth doing as a periodic
  health check, not only during conversion.

### `.gitignore` note

`.env.example` is the deliberate exception to the `.env`/`.env.*` exclusion
rules — it needs an explicit `!.env.example` negation in the root
`.gitignore`, or the `.env.*` pattern silently excludes it too (found only
once a `.env.example` was actually tracked for the first time; this had been
silently broken since the very first host's rollout).

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
