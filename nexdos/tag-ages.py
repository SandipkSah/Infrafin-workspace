#!/usr/bin/env python3
# Read-only: walks the registry's on-disk tag pointers and uses each tag's
# "current/link" file mtime as a proxy for "when this tag was last pushed".
# Writes a full sorted CSV (oldest first) + prints a per-repo age-bucket summary.
# Makes no writes/deletes anywhere except the output CSV it creates.

import os, time, datetime, csv
from collections import defaultdict

ROOT = "/var/lib/docker/volumes/gitlab_registry-data/_data/docker/registry/v2/repositories"
OUT_CSV = os.path.expanduser("~/gitlab/tag-ages.csv")

now = time.time()
rows = []  # (repo, tag, mtime)

for dirpath, dirnames, filenames in os.walk(ROOT):
    if os.path.basename(dirpath) == "tags" and os.path.basename(os.path.dirname(dirpath)) == "_manifests":
        manifests_dir = os.path.dirname(dirpath)
        repo = os.path.relpath(os.path.dirname(manifests_dir), ROOT)
        for tag in dirnames:
            link_path = os.path.join(dirpath, tag, "current", "link")
            try:
                mtime = os.path.getmtime(link_path)
            except OSError:
                continue
            rows.append((repo, tag, mtime))

rows.sort(key=lambda r: r[2])  # oldest first

with open(OUT_CSV, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["repo", "tag", "last_pushed_iso", "age_days"])
    for repo, tag, mtime in rows:
        age_days = (now - mtime) / 86400
        w.writerow([repo, tag, datetime.datetime.fromtimestamp(mtime).isoformat(), f"{age_days:.1f}"])

print(f"Wrote {len(rows)} tag entries to {OUT_CSV}\n")

by_repo = defaultdict(list)
for repo, tag, mtime in rows:
    by_repo[repo].append(mtime)

print(f"{'repo':45s} {'count':>6s} {'oldest(d)':>10s} {'newest(d)':>10s} {'<7d':>5s} {'7-30d':>6s} {'30-90d':>7s} {'90-180d':>8s} {'>180d':>6s}")
for repo in sorted(by_repo, key=lambda r: -len(by_repo[r])):
    mtimes = by_repo[repo]
    ages = [(now - m) / 86400 for m in mtimes]
    oldest, newest = max(ages), min(ages)
    b = [
        sum(1 for a in ages if a < 7),
        sum(1 for a in ages if 7 <= a < 30),
        sum(1 for a in ages if 30 <= a < 90),
        sum(1 for a in ages if 90 <= a < 180),
        sum(1 for a in ages if a >= 180),
    ]
    print(f"{repo:45s} {len(mtimes):6d} {oldest:10.1f} {newest:10.1f} {b[0]:5d} {b[1]:6d} {b[2]:7d} {b[3]:8d} {b[4]:6d}")
