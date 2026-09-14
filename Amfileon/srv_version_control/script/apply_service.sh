#!/usr/bin/env bash
# Copies one service's already-generated sanitize_service_files.py output
# into the REAL /srv/docker/<service>/ directory -- and does NOTHING else.
#
# By default this NEVER modifies, overwrites, or appends to any file that
# already exists in the real service directory (never deletes anything
# either) -- it only ever CREATES new files:
#   - every <file>.sanitized from the staging output -> copied to
#     <real-dir>/<file>.sanitized, sitting alongside the untouched real
#     <file> (compose file included -- the real docker-compose.yaml is never
#     replaced or edited by this script)
#   - the staged .gitignore (if any) -> copied to <real-dir>/.gitignore,
#     but ONLY if <real-dir>/.gitignore doesn't already exist (never
#     overwrites one you've already reviewed/edited by hand)
#
# Set APPLY_SERVICE_UPDATE=1 to instead allow overwriting an existing
# .sanitized/.gitignore in place (a direct `cp` over the old content -- the
# file is never removed, its content is just refreshed). Still shows a diff
# and asks y/N first, same as everything else here. Use this when
# sanitize_service_files.py itself changed and old output needs refreshing --
# never needed for a first-time apply.
#
# .env.additions / .env.example.additions are deliberately NOT applied by
# this script at all -- whether and how to actually move a var into a real
# .env is your call, made by hand, separately. This script's only job is
# getting the redacted, git-trackable copies into place.
#
# Nothing here restarts any service, and nothing here needs docker.
set -uo pipefail

SERVICE="${1:?usage: apply_service.sh <service-name>}"
UPDATE="${APPLY_SERVICE_UPDATE:-0}"
BASE_DIR="${APPLY_SERVICE_BASE_DIR:-/srv/docker}"
# Defaults to ~ssa's staging tree, not $HOME -- this script is typically run
# as root (since /srv/docker is root-owned), and root's $HOME is /root, not
# where sanitize_service_files.py actually wrote its output as ssa. Override
# with APPLY_SERVICE_STAGE_ROOT if the staging tree lives somewhere else.
STAGE_ROOT="${APPLY_SERVICE_STAGE_ROOT:-/home/ssa/srv_version_control/env-variables}"
STAGE_DIR="$STAGE_ROOT/$SERVICE"
REAL_DIR="$BASE_DIR/$SERVICE"

if [ ! -d "$STAGE_DIR" ]; then
  echo "no staged output for '$SERVICE' at $STAGE_DIR -- run sanitize_service_files.py --write for it first."
  exit 1
fi
if [ ! -d "$REAL_DIR" ]; then
  echo "no such real service directory: $REAL_DIR"
  exit 1
fi

confirm() {
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

copied_any=0

for sanitized in "$STAGE_DIR"/*.sanitized; do
  [ -e "$sanitized" ] || continue
  base="$(basename "$sanitized" .sanitized)"
  dest="$REAL_DIR/$base.sanitized"

  if [ -e "$dest" ]; then
    if [ "$UPDATE" != "1" ]; then
      echo "=== $base.sanitized already exists at $dest -- skipping (never overwritten) ==="
      continue
    fi
    if cmp -s "$sanitized" "$dest"; then
      echo "=== $base.sanitized already up to date at $dest -- skipping ==="
      continue
    fi
    echo "=== $base.sanitized differs from what's staged now -- diff (line numbers/shape only, content redacted): ==="
    # Never print the actual differing text -- both sides of this diff are
    # .sanitized files, which can still hold a real, un-redacted secret right
    # up until the fix that's being applied here (this is exactly how one
    # leaked into a chat transcript during db1's rollout: the raw diff of an
    # old-buggy-version vs new-fixed-version was pasted back for review).
    # Only the diff's structural markers (line numbers, ---, change type)
    # carry no secret content, so those are all that's shown.
    diff "$dest" "$sanitized" 2>/dev/null | sed -E 's/^([<>]).*/\1 [line content redacted for safety -- review the actual file yourself if needed]/' || true
    echo "=== end diff ==="
    if confirm "Overwrite $dest with the refreshed version (old content replaced, file never removed)?"; then
      cp "$sanitized" "$dest"
      echo "updated: $dest"
      copied_any=1
    else
      echo "left as-is: $dest"
    fi
    continue
  fi

  echo "=== $base.sanitized (new file, real $base is untouched) ==="
  if confirm "Create $dest?"; then
    cp "$sanitized" "$dest"
    echo "created: $dest"
    copied_any=1
  else
    echo "skipped: $base.sanitized"
  fi
done

if [ -f "$STAGE_DIR/.gitignore" ]; then
  dest_gitignore="$REAL_DIR/.gitignore"
  if [ -e "$dest_gitignore" ]; then
    if [ "$UPDATE" = "1" ] && ! cmp -s "$STAGE_DIR/.gitignore" "$dest_gitignore"; then
      echo
      echo "=== $dest_gitignore differs from what's staged now -- diff: ==="
      diff "$dest_gitignore" "$STAGE_DIR/.gitignore" || true
      echo "=== end diff ==="
      if confirm "Overwrite $dest_gitignore with the refreshed version?"; then
        cp "$STAGE_DIR/.gitignore" "$dest_gitignore"
        echo "updated: $dest_gitignore"
        copied_any=1
      else
        echo "left as-is: $dest_gitignore"
      fi
    else
      echo
      echo "=== $dest_gitignore already exists and matches (or UPDATE not set) -- not touching it. Staged content for reference: ==="
      cat "$STAGE_DIR/.gitignore"
      echo "=== merge by hand if needed ==="
    fi
  else
    echo
    echo "=== staged .gitignore for this service ==="
    cat "$STAGE_DIR/.gitignore"
    echo "=== end ==="
    if confirm "Create $dest_gitignore with this content?"; then
      cp "$STAGE_DIR/.gitignore" "$dest_gitignore"
      echo "created: $dest_gitignore"
      copied_any=1
    fi
  fi
fi

if [ -f "$STAGE_DIR/.env.additions" ] || [ -f "$STAGE_DIR/.env.example.additions" ]; then
  echo
  echo "note: $STAGE_DIR/.env.additions and/or .env.example.additions exist but were"
  echo "NOT applied -- this script never touches .env/.env.example. Moving a var into"
  echo "the real .env is a separate, deliberate step you do by hand, whenever you decide to."
fi

echo
if [ "$copied_any" -eq 1 ]; then
  if [ "$UPDATE" = "1" ]; then
    echo "Done with $SERVICE. New files were created and/or existing ones refreshed in place -- nothing was removed."
  else
    echo "Done with $SERVICE. Only new .sanitized/.gitignore files were created -- nothing existing was touched."
  fi
else
  echo "Done with $SERVICE. Nothing was created or updated (all skipped, already existed, or already up to date)."
fi
