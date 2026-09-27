# Conda GPU image upgrade — working notes

ClickUp: **Research-Conda-Docker-Images** — `/srv/docker/conda` on gpu1. Start: update
the image, include uv + uv config in containers, test it in your own container, get it
tested by the team, then hand off for rollout.

**gpu1 is the source of truth.** These files mirror what's under `/srv/docker/conda/` on
gpu1 for reference and history — edit there and copy back here, not the other way round.

## Where things stand

- Live prod image: `amfileon/conda`, built from `/srv/docker/conda/Dockerfile` — **untouched**
  the whole time. Every other `conda-*` container keeps running on it.
- Test container: `conda-ssa`, swapped via `docker-compose.ssa-test.yaml` (see below) onto
  a throwaway tag. Only `conda-ssa` is ever affected. **Currently running
  `amfileon/conda:ssa-test-v2`** — the current candidate.
- Three Dockerfile variants explored, in order — `ssa-test` (conservative base upgrade) →
  `ssa-test-max` (aggressive, "upgrade everything") → `ssa-test-v2` (built from `-max`,
  incorporating real feedback from a teammate who independently tested `-max` on gpu1 and
  from a second teammate's tool requests). **`v2` is the current recommendation** — it fixes
  everything `-max` had open and adds five more CLI tools the team asked for.

## A note on how these Dockerfiles are written

Both `Dockerfile.ssa-test` and `Dockerfile.ssa-test-max` are deliberately written as a
**minimal diff against the original `Dockerfile`** — same structure, same order, same
command style, `sudo` left in where the original had it, etc. Every line that differs is
tagged with why:

- `[BASE SWAP]` — forced by moving off `gpuci/miniconda-cuda`; the original line would
  literally error on the new base (wrong apt keys, no conda preinstalled, `/bin/sh` is dash
  not bash, etc.)
- `[FIX]` — a real bug found during testing (the ToS gate, the uv/CA issue), unrelated to
  version numbers but required for the thing to work at all
- `[UPGRADE]` — an actual version or library upgrade, the actual point of the exercise
- `[TEAM FEEDBACK]` — added in `ssa-test-v2` only: a change made in direct response to a
  teammate's feedback after testing `-max` themselves, not something decided unilaterally

Nothing else was reformatted, reordered, or "tidied" for its own sake. Run `diff Dockerfile
Dockerfile.ssa-test` (or `-max`, or `-v2`) to see exactly this and nothing more.

**Both files were rewritten this way on 2026-09-13, after `ssa-test` had already been built
and validated once under an earlier, more heavily-reformatted version.** The version
currently running as `amfileon/conda:ssa-test` on `conda-ssa` predates this rewrite and
predates the `UV_SYSTEM_CERTS` fix — the test results in the status tables below are still
accurate for what was tested, but re-verify after the next rebuild from these exact files.
`ssa-test-max` was already rebuilt once from an equivalent minimal-diff version and tested
clean (see its table) — but that rebuild happened *before* a missing `/etc/profile.d/conda.sh`
line was caught and restored, so it too needs one more rebuild before being considered final.

## Status at a glance

### `Dockerfile.ssa-test` (Ubuntu 22.04, CUDA 12.4.1) — built, tested on `conda-ssa`

| Component | Before | After | Status |
|---|---|---|---|
| Base image | `gpuci/miniconda-cuda:11.4-devel-ubuntu20.04` (dead, wouldn't rebuild) | `nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04` | ✅ built, running |
| conda | unspecified | `26.7.2` | ✅ confirmed |
| Python | unspecified | `3.10.21` | ✅ confirmed |
| uv | internal `registry.amf/data/base-image:2025.11.1` (opaque version) | `ghcr.io/astral-sh/uv:0.7.20` | ⚠️ installed, but **can't reach `pypi.amf`** (`UnknownIssuer` — uv ignores OS trust store) |
| TensorFlow | `conda install tensorflow` → running container had `2.20.0` | `pip install tensorflow[and-cuda]` → `2.21.0` | ✅ confirmed — trained on RTX A6000, XLA + cuDNN 9.25.1 loaded |
| GPU / CUDA / cuDNN | CUDA 11.4, cuDNN unknown | CUDA 12.4, cuDNN 9.25.1 | ✅ confirmed — `nvidia-smi -L` sees the A6000, TF sees the GPU |
| anaconda metapackage | unpinned, ToS-blocked | unpinned, resolved after `conda tos accept` fix | ✅ installed |
| scikit-learn-intelex | unpinned | resolved `2023.1.1` | ✅ installed (not individually exercised) |
| Node / yarn | `20.19.3` / floating | unchanged, resolved `1.22.22` | ✅ confirmed |
| glab | pinned `1.65.0` | unchanged | ✅ confirmed |
| `curl` → `pypi.amf` | — | — | ❌ SSL cert verify failed — OS trust store isn't picking up the Amfileon CA reliably |
| `pip` → `pypi.amf` | — | — | ⚠️ not conclusively re-tested after the CA issue surfaced (works via `trusted-host` bypass regardless of cert validity) |

**Net:** base upgrade + GPU + TensorFlow all work. **uv config in containers — the actual ticket ask — is not yet working**, blocked on the CA / `UV_NATIVE_TLS` fix.

### `Dockerfile.ssa-test-max` (Ubuntu 24.04, CUDA 12.6.3, "upgrade everything") — build in progress

| Component | Before | After | Status |
|---|---|---|---|
| Base image | `nvidia/cuda:12.4.1-cudnn-devel-ubuntu24.04` | corrected → `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04` | ❌ first tag didn't exist → ✅ corrected tag pulls fine |
| apt packages | — | `mlocate` → `plocate` (noble dropped `mlocate`) | ❌ failed first attempt → ✅ fix applied, build completed |
| conda flavor | Miniconda + `defaults`/`anaconda` | Miniforge + conda-forge, unpinned stack | ✅ built — `numpy 2.5.3`, `pandas 3.0.5`, `scipy 1.18.1`, `scikit-learn 1.9.1` |
| Python | `3.10` (downgraded from 3.14) | `3.12.14` (installed directly) | ✅ confirmed |
| uv | hardcoded `0.7.20` | build-arg, built with `0.12.13` | ✅ confirmed |
| `UV_NATIVE_TLS=true` (now `UV_SYSTEM_CERTS=true`) | absent | added | ✅ **fixed the `ssa-test` uv/CA problem** — `uv pip install` now resolves from `pypi.amf` |
| `curl` / entrypoint CA install | broken on `ssa-test` | same `entrypoint.sh`, this base | ✅ `curl https://pypi.amf/...` → `200` on a **clean recreate**, no manual fixup — the CA install is reliable, `ssa-test`'s failure wasn't a fundamental entrypoint bug |
| TensorFlow | pinned to whatever conda gave | unpinned `tensorflow[and-cuda]` → `2.21.0` | ✅ confirmed — trained on RTX A6000, cuDNN `9.26.0` |
| glab | `1.65.0` | `1.117.0` | ✅ confirmed |
| GPU / CUDA 12.6 forward-compat | — | Driver `12.6.0` / Runtime `12.9.0` / Toolkit `12.5.0` | ✅ confirmed working, as predicted from the `ssa-test` evidence |

**Net: fully validated, and was tested independently by a teammate on gpu1 (their own throwaway compose service, not `conda-ssa`) — "seems to work."** Their feedback (below) is what produced `ssa-test-v2`; this variant is now superseded by it.

### `Dockerfile.ssa-test-v2` (built from `-max` + team feedback) — **current candidate, fully validated**

| Component | Before | After | Status |
|---|---|---|---|
| uv source | `ghcr.io/astral-sh/uv` (upstream, `-max`'s choice) | reverted toward `registry.amf/data/base-image:2025.11.1` (team's HTTP/2-safe internal build) | ⏸️ **deferred** — see CA/registry saga below; currently still on upstream so the file stays buildable |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | native installer (`claude.ai/install.sh`) | ✅ confirmed — lands under `/root/.local/bin`, copied to `/usr/local/bin` for non-root PATH |
| Codex CLI | absent | `chatgpt.com/codex/install.sh` | ✅ confirmed, same copy-to-`/usr/local/bin` fix |
| herdr | absent | `herdr.dev/install.sh` | ✅ confirmed, same fix |
| Pi (coding agent CLI) | absent | `npm install -g --prefix /opt/pi-npm @earendil-works/pi-coding-agent` via an isolated Node 22 (image defaults to Node 20.19.3 for everything else) | ✅ confirmed, after two real bugs found and fixed (below) |
| Cursor CLI | absent | native installer (`cursor.com/install`) | ✅ confirmed — ships a whole app bundle, not a single binary; copied out from under `/root` (700) as a directory, not a single file, with both `agent`/`cursor-agent` symlinks re-created |
| uv/pip/CA → `pypi.amf` | — | — | ✅ confirmed on a clean recreate |
| GPU / TensorFlow | — | — | ✅ confirmed, RTX A6000, trained fine |

**Two real bugs found and fixed while adding these, both worth knowing about if this pattern gets reused:**
1. **Pi's `npm install -g` silently ignored the isolated Node 22 and installed into the default Node 20.19.3's directory instead** (confirmed: `/usr/local/bin/pi` ended up a dangling symlink to a v22 path that was never populated; the real files landed under v20.19.3, an older cached version). Root cause: almost certainly an inherited npm prefix config (e.g. `/root/.npmrc`) overriding per-version isolation. Fixed with an explicit `--prefix /opt/pi-npm` flag, which overrides any `.npmrc` setting — verified locally before applying.
2. **Cursor's installer ships many files** (JS bundles, native `.node` modules, a full app tree), not a single binary like the other three — a plain single-file `cp` would have broken it. Fixed by copying the whole `~/.local/share/cursor-agent/` directory out from under `/root`, then re-creating both symlinks pointing at the copy. Verified locally (sandboxed test on a dev machine, not gpu1) that the relocated binary still runs correctly before touching the real build.

**"pi" turned out to be a real, verifiable tool** — an open-source AI coding agent CLI (earendil-works, MIT license), not a typo or a portfolio-management library as first guessed. Confirmed via web search before adding it, to avoid guessing a dead install URL.

#### The uv/CA/registry saga (why uv is still on upstream in `v2`)

Team feedback: the original `registry.amf/data/base-image:2025.11.1` uv build isn't
arbitrary — it was **recompiled without HTTP/2 support specifically because `pypi.amf`
doesn't handle HTTP/2 reliably**. The upstream `ghcr.io/astral-sh/uv` build uses HTTP/2 and
risks breaking against `pypi.amf`, even though testing against it here didn't happen to hit
the problem. Tried switching back — hit two **separate, sequential, pre-existing** problems,
neither caused by this work:

1. **gpu1's Docker daemon (and the host OS itself) didn't trust the Amfileon internal CA**
   (`CN=amf, O=Amfileon AG`) for `registry.amf`/`gitlab.amf`. Confirmed this affects the
   **untouched production `Dockerfile` too** — not specific to any file here. Fixed at the
   host level:
   ```bash
   sudo cp /srv/docker/proxy/CA.pem /usr/local/share/ca-certificates/amfileon-CA.crt
   sudo update-ca-certificates
   ```
   Verified with `wget --ca-certificate=/srv/docker/proxy/CA.pem https://gitlab.amf/`
   (clean `200 OK`) *before* touching the system-wide trust store, then confirmed the
   system-wide fix with plain `wget gitlab.amf` (no cert flag) succeeding after.
2. **Past that: `403 Forbidden`, then after a fresh GitLab personal access token,
   `insufficient_scope: authorization failed`.** Root cause: no project-level (Reporter+)
   access to `data/base-image` on gitlab.amf. Not a cert/config problem — a permissions one.
   (Side note ruled out along the way: `registry.amf` and `registry.git.amf` resolve to the
   same IP, but `registry.git.amf` is unhealthy — `503` on every request — so it's not a
   viable alternate hostname either way.)

**Parked** until someone with `data/base-image` access grants it (or issues a deploy token).
`Dockerfile.ssa-test-v2` has both lines ready — the internal source is commented out right
next to the active upstream one, so the swap is a two-line edit once access is sorted:
```dockerfile
# COPY --from=registry.amf/data/base-image:2025.11.1 /bin/uv /bin/uvx /bin/
COPY --from=uv /uv /uvx /bin/
```

## 1. `Dockerfile.ssa-test` — modernize the base, minimum viable upgrade

Built and running as `amfileon/conda:ssa-test` on `conda-ssa`. Smoke-tested successfully.

- **Base:** `gpuci/miniconda-cuda:11.4-devel-ubuntu20.04` (dead RAPIDS-CI image, wouldn't
  even rebuild anymore — `conda install anaconda` hung on "Solving environment" because
  Anaconda now gates its channels behind a Terms-of-Service acceptance) →
  `nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04`
  - `12.4.1` chosen because gpu1's driver (`550.163.01`) reports CUDA `12.4` as its native
    ceiling, and `nvcc` is actually used in the container (`devel`, not `runtime`)
- **Miniconda installed into `/opt/conda`** (not the WIP draft's `/opt/miniconda3`) so
  `entrypoint.sh`'s `chown /opt/conda/pkgs/cache` and everyone's paths keep working
- Added `conda tos accept` for `pkgs/main` / `pkgs/r` / `pkgs/msys2` — the actual fix for
  the ToS hang
- `uv` moved from `registry.amf/data/base-image:2025.11.1` (internal, opaque version) to
  `ghcr.io/astral-sh/uv:0.7.20` (pinned upstream, no internal registry auth needed at build)
- `conda install tensorflow` → `pip install tensorflow[and-cuda]` (official wheel, bundles
  matching CUDA/cuDNN instead of a lagging conda-forge build)
- Removed: dead `apt-key adv` lines (NVIDIA image ships its own keyring) and a no-op
  `apt install -y ... --force-yes` fragment with no packages

**Validated on `conda-ssa`** (see `uvcheck.sh` output from testing):
uv `0.7.20`, conda `26.7.2`, Python `3.10.21`, node/yarn, `nvcc` CUDA 12.4, `glab 1.65.0`,
`uv venv` works, TensorFlow `2.21.0` trains on the RTX A6000 (XLA compiled, cuDNN 9.25.1
loaded, `tf.config.list_physical_devices('GPU')` sees it).

**Open issue, not yet fixed in this file:** `curl` and `uv` both failed to reach
`pypi.amf` — `curl: SSL certificate ... unable to get local issuer certificate`, `uv:
invalid peer certificate: UnknownIssuer`. Two separate causes:
1. **uv ignores the OS trust store by default** (bundles its own Mozilla roots) — needs
   `ENV UV_NATIVE_TLS=true` added to the Dockerfile. (Already included in
   `Dockerfile.ssa-test-max` below; not yet backported here.)
2. Need to confirm `entrypoint.sh`'s
   ```sh
   cp /etc/certs/CA.pem /usr/local/share/ca-certificates/CA.crt
   update-ca-certificates
   ```
   actually survives a **clean** container recreate (no manual re-run) — if uv/curl only
   worked after re-running that by hand, it'll break again for every other user.

**Also found, unrelated pre-existing bug in `entrypoint.sh`:**
`glab config set ca_cert /etc/certs/CA.PEM` — wrong case, the mounted file is `CA.pem`.
glab silently falls back to `skip_tls_verify true` instead of actually verifying.

## 2. `Dockerfile.ssa-test-max` — "upgrade as many libraries as possible"

Goal changed mid-task from "modernize the base" to "get as much of the stack onto current
versions as possible." Bigger, riskier changes — **not yet built** on gpu1.

- **Base:** `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`. Originally tried
  `12.4.1-cudnn-devel-ubuntu24.04` — **doesn't exist**. Checked Docker Hub's tag list
  directly: no `12.4.x` or `12.5.x` tag is published for `ubuntu24.04` at all; `12.6.0` is
  the earliest. Picked `12.6.3` (latest patch in that line) instead of jumping to the
  `13.x` line, which needs a much newer (R580+) driver than gpu1's R550 — the `12.x` jump
  is safe because the *validated* `ssa-test` run already showed TensorFlow's bundled wheel
  running a `12.9` CUDA runtime fine on this exact driver (forward/minor-version
  compatibility, empirically proven, not just theoretical).
- **Miniforge instead of Miniconda** — defaults to conda-forge, no Anaconda ToS gate,
  tracks upstream releases much faster than Anaconda's `defaults` channel.
- **Dropped the `anaconda` metapackage** (a curated, deliberately-conservative ~3GB bundle)
  for an **unpinned, explicit conda-forge package list** — lets the solver pick the newest
  mutually-compatible version of everything instead of Anaconda's lagging curation. This is
  the actual lever for "upgrade as many libs as possible"; everything else here is smaller.
- Python `3.10` → `3.12`, installed directly (the `ssa-test` file installs then downgrades
  from whatever Miniconda's latest installer ships, which is wasteful churn)
- `glab` bumped `1.65.0` → `1.117.0` (confirmed current via the CLI's own update-check
  output during testing)
- `uv` version is now a build arg instead of hardcoded:
  ```
  ARG UV_VERSION=0.7.20
  FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
  ...
  COPY --from=uv /uv /uvx /bin/
  ```
  This also fixes an earlier build error — `COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION}`
  directly doesn't work (`variable expansion is not supported for --from`); BuildKit
  requires a named stage instead. Build with e.g. `--build-arg UV_VERSION=0.12.13` (the
  latest tag as of 2026-09-13 — check `https://api.github.com/repos/astral-sh/uv/releases/latest`
  for current).
- Includes the `UV_NATIVE_TLS=true` fix from the start (see the open issue above)

**Trade-off to flag explicitly when handing this off for team testing:** this is a much
bigger jump than "same stack, newer CUDA" — a Python minor-version bump plus a different
package channel entirely. Higher chance of breaking existing notebooks/scripts (numpy 2.x
/ pandas 2.x behavior changes, deprecated APIs, etc.) than the conservative `ssa-test`
variant. Worth being upfront about that distinction before asking people to test.

## Files here

| file | purpose |
|---|---|
| `Dockerfile` | **read-only baseline** — exact copy of the live prod `/srv/docker/conda/Dockerfile` on gpu1, for diffing against. Never edit this copy; if prod changes, re-copy it. |
| `Dockerfile.ssa-test` | Ubuntu 22.04 / CUDA 12.4.1 — built & GPU/TF/uv-tested on gpu1 |
| `Dockerfile.ssa-test-max` | Ubuntu 24.04 / CUDA 12.6.3, conda-forge, "upgrade everything" — validated, superseded by `-v2` |
| `Dockerfile.ssa-test-v2` | built from `-max` + team feedback (native tool installers, Pi, Cursor) — **current candidate, fully validated** |
| `docker-compose.ssa-test.yaml` | isolates the swap to the `ssa` service only, no other container touched. Currently pointed at `amfileon/conda:ssa-test-v2`. |
| `uvcheck.sh` | in-container check: configs mounted, CA trust to `pypi.amf`, uv/pip install from the internal index, GPU visible to TensorFlow |

## Compose topology, for context (`docker-compose.yaml` on gpu1)

- `x-template: &template` at the top of the file is a YAML anchor (`build: .`,
  `image: amfileon/conda`, GPU reservation, caps, etc.) — merged into every `conda-*`
  service via `<<: *template` (YAML merge key). Every `conda-*` container therefore shares
  one image build.
- The merge is **shallow** — keys on the service win, and the anchor has no
  `volumes`/`environment`/`ports`, so every service repeats its own full set of those.
- "Regular"/internal users mount `./uv.toml` + `./pip.conf`; external users (like `ssa`)
  mount `./uv_external.toml` + `./pip_external.conf` — both to `/etc/uv/uv.toml` /
  `/etc/pip.conf` inside the container. Not every service has this mount yet — adding it to
  the ones that don't is the other half of the ticket ("uv config in containers").
- `docker-compose.override.yaml` (auto-loaded by compose) adds an unrelated `sidekick`
  (MinIO proxy) service and extends `jba` with networking/env — confirmed it does **not**
  touch `ssa`.

## Reproducing the isolated test on gpu1

```bash
cd /srv/docker/conda

# build under a throwaway tag -- never rebuild `amfileon/conda` directly during testing
docker build -f Dockerfile.ssa-test-v2 -t amfileon/conda:ssa-test-v2 . 2>&1 | tee build.ssa-test-v2.log

# swap only conda-ssa onto it
docker compose \
  -f docker-compose.yaml -f docker-compose.override.yaml -f docker-compose.ssa-test.yaml \
  up -d --no-deps --force-recreate ssa

# verify
docker exec -u ssa -it conda-ssa bash -l
./uvcheck.sh
```

(swap `ssa-test-v2` for `ssa-test` or `ssa-test-max` to reproduce either of the earlier variants instead)

Rollback: delete `docker-compose.ssa-test.yaml`, re-run the same `up` command without it —
`conda-ssa` goes back to `amfileon/conda`, nothing else was ever touched.

## Rollout plan (once a variant is fully validated by the team)

1. `cp Dockerfile Dockerfile.$(date +%F).bak` on gpu1
2. Put the validated content into `Dockerfile`
3. `docker compose build && docker compose up -d` — recreates every `conda-*` container
4. Add the matching `uv*.toml` / `pip*.conf` mount pair to any service that's missing it
5. Clean up: remove `docker-compose.ssa-test.yaml`, `docker image rm amfileon/conda:ssa-test[-max]`

## Security note

`uv.toml`, `uv_external.toml`, `pip.conf`, and `pip_external.conf` on gpu1 carry live
credentials embedded directly in their index URLs. Worth rotating the `amfileon` /
`external` pypi tokens at some point, and confirming `.gitignore` (wherever these ever get
committed) excludes `uv*.toml`, `pip*.conf`, and `.env*`.

## Open items before rollout

- [x] ~~Add `UV_NATIVE_TLS=true`/`UV_SYSTEM_CERTS=true` and confirm `uv`/`curl` reach
      `pypi.amf` on a clean recreate~~ — done, confirmed clean on `-max` and `-v2`
- [x] ~~Decide which variant goes to the team~~ — `ssa-test-v2`, incorporating a teammate's
      real feedback after testing `-max` themselves
- [ ] **Get `data/base-image` registry access granted** (or a deploy token) so `v2`'s uv
      line can switch back to the team's HTTP/2-safe internal build — see the uv/CA/registry
      saga above. Host-level CA trust is already fixed; this is purely a project-permissions
      ask now.
- [ ] Fix `entrypoint.sh`'s `glab config set ca_cert /etc/certs/CA.PEM` case bug
- [ ] Pin `tensorflow[and-cuda]==2.21.0` once confirmed stable, so rollout doesn't silently
      grab a newer/untested version
- [ ] Add the `uv*.toml`/`pip*.conf` mounts to any `conda-*` service missing them
- [ ] Decide whether Pi/Cursor/Codex/herdr are wanted broadly (team-wide) or just for the
      people who asked — they're in `v2` now, but that was two individual requests, not a
      team decision
- [ ] `pi --version` on gpu1 reports `0.74.2`, older than what a direct (non-mirrored)
      install gets (`0.85.1`) — likely gpu1's npm resolves through an internal mirror/proxy
      with stale cached metadata (same pattern as `pypi.amf` for Python), not a broken
      install. Not blocking, just unconfirmed.
