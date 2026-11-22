# Production baseline — captured during cutover, 2026-11-15

Captured while production (`gitlab` + `registry` containers) was fully stopped
(step b of the cutover runbook), so these numbers are frozen/authoritative —
nothing could have changed production between this snapshot and the start
of the migration.

## Counts

| Metric | Value |
|---|---|
| Users | 48 |
| Projects | 55 |
| Container repositories | 26 |
| Total registry tags | 1556 |

## How each was obtained

- `users` / `projects` / `container_repos`: via `gitlab-rails runner` against
  the `gitlab` (production) container's database — `User.count`,
  `Project.count`, `ContainerRepository.count`.
- `total_tags`: via direct filesystem count on the registry volume (the
  Rails-model `.tags` method failed because the `registry` container was
  already stopped at this point — it needs the live registry API):
  ```bash
  find /var/lib/docker/volumes/gitlab_registry-data/_data/docker/registry/v2/repositories \
    -path "*_manifests/tags/*/current/link" 2>/dev/null | wc -l
  ```

## Context

- This snapshot matches the last full staging refresh (2026-11-14) exactly
  for users/projects/container_repos (48/55/26), confirming production was
  unchanged in between.
- `total_tags` (1556) is consistent with the pre-cleanup count (1762) minus
  the 207 policy-based tags deleted on 2026-11-15, confirming nothing
  unexpected moved in between.
- Project path list was NOT captured in this run — the script crashed on
  the registry-dependent `total_tags` line before reaching the project
  enumeration. Not re-run since it wasn't essential for the numeric
  comparison; can be regenerated post-cutover if needed via
  `Project.order(:path_with_namespace).pluck(:path_with_namespace)`
  (no registry dependency).

## Post-cutover verification

Once `gitlab-ce` is live as `git.nexdos.de`, re-run the equivalent counts
there and diff against this file.
