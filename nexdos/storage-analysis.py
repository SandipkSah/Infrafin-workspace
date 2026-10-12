#!/usr/bin/env python3
# Read-only: parses a `registry garbage-collect --dry-run` log (the "<repo>: marking blob <digest>"
# lines) and cross-references real blob sizes on disk to estimate, per repo:
#   - inclusive size: everything it references (double-counts layers shared with other repos)
#   - exclusive size: blobs referenced ONLY by that repo (the realistic "delete this repo's tags,
#     GC would free this much" number)
# Makes no writes/deletes anywhere.

import re, collections, os

LOG = os.path.expanduser("~/gitlab/gc-dryrun.log")   # <-- adjust to the real path on nexdos
BLOBROOT = "/var/lib/docker/volumes/gitlab_registry-data/_data/docker/registry/v2/blobs/sha256"

repo_blobs = collections.defaultdict(set)
pat = re.compile(r"^(.*?): marking blob (sha256:[0-9a-f]{64})")

with open(LOG, "r", errors="ignore") as f:
    for line in f:
        m = pat.match(line)
        if m:
            repo_blobs[m.group(1)].add(m.group(2))

size_cache = {}
def blob_size(digest):
    if digest not in size_cache:
        d = digest.split(":", 1)[1]
        path = os.path.join(BLOBROOT, d[:2], d, "data")
        try:
            size_cache[digest] = os.path.getsize(path)
        except OSError:
            size_cache[digest] = 0
    return size_cache[digest]

blob_repo_count = collections.Counter()
for repo, blobs in repo_blobs.items():
    for b in blobs:
        blob_repo_count[b] += 1

rows = []
for repo, blobs in repo_blobs.items():
    inclusive = sum(blob_size(b) for b in blobs)
    exclusive = sum(blob_size(b) for b in blobs if blob_repo_count[b] == 1)
    rows.append((repo, inclusive, exclusive, len(blobs)))

rows.sort(key=lambda r: -r[1])
gb = lambda b: b / 1024 / 1024 / 1024

print(f"{'repo':45s} {'inclusive(GB)':>15s} {'exclusive(GB)':>15s} {'blobs':>8s}")
for repo, inc, exc, n in rows:
    print(f"{repo:45s} {gb(inc):15.2f} {gb(exc):15.2f} {n:8d}")

total_inc = sum(r[1] for r in rows)
total_exc = sum(r[2] for r in rows)
print(f"\nSum inclusive (double-counts shared layers): {gb(total_inc):.2f} GB")
print(f"Sum exclusive (realistic reclaim estimate):    {gb(total_exc):.2f} GB")
