#!/usr/bin/env python3
# Read-only: simulates the proposed cleanup policies against REAL tag data and prints how much
# would actually be reclaimed. For each tag, reads its manifest JSON directly (recursing into
# manifest lists/OCI indexes if present) to get its exact set of referenced blob digests - this is
# more precise than repo-level attribution, since it lets us tell which blobs are referenced ONLY
# by tags that would be EXPIRED vs tags that would be KEPT.
# Makes no writes/deletes anywhere.

import os, re, json, time
from collections import defaultdict

ROOT = "/var/lib/docker/volumes/gitlab_registry-data/_data/docker/registry/v2/repositories"
BLOBROOT = "/var/lib/docker/volumes/gitlab_registry-data/_data/docker/registry/v2/blobs/sha256"

# --- policy definitions ---
PRESERVE_RE = re.compile(r'^(main|master|stable|latest|release-.*|v[0-9]+\.[0-9]+\.[0-9]+)$')

CATEGORY_A = {
    "dagster/user-code/pipeline",
    "idp/nexdos_app/backend",
    "dagster/ops/images/nexdos-datalore-agent",
}

def policy_for(repo):
    if repo.endswith("/cache"):
        return dict(keep=3, expire_days=7, preserve=False)
    if repo in CATEGORY_A:
        return dict(keep=10, expire_days=90, preserve=True)
    return dict(keep=25, expire_days=90, preserve=True)  # category C (+ dormant repos, see note)

# --- blob helpers ---
def blob_path(digest):
    d = digest.split(":", 1)[1]
    return os.path.join(BLOBROOT, d[:2], d, "data")

size_cache = {}
def blob_size(digest):
    if digest not in size_cache:
        try:
            size_cache[digest] = os.path.getsize(blob_path(digest))
        except OSError:
            size_cache[digest] = 0
    return size_cache[digest]

manifest_cache = {}
def manifest_digests(digest, seen=None):
    """Return the set of all digests (manifest itself + config + layers, recursing into
    manifest lists/OCI indexes) referenced starting from this manifest digest."""
    if digest in manifest_cache:
        return manifest_cache[digest]
    if seen is None:
        seen = set()
    if digest in seen:
        return set()
    seen.add(digest)
    digests = {digest}
    try:
        with open(blob_path(digest), "r", errors="ignore") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        manifest_cache[digest] = digests
        return digests
    if "manifests" in data:  # manifest list / OCI index
        for m in data["manifests"]:
            digests |= manifest_digests(m["digest"], seen)
    else:
        cfg = data.get("config", {}).get("digest")
        if cfg:
            digests.add(cfg)
        for layer in data.get("layers", []):
            digests.add(layer["digest"])
    manifest_cache[digest] = digests
    return digests

# --- walk all tags ---
now = time.time()
# tag_info[repo] = list of (tag, age_days, manifest_digest)
tag_info = defaultdict(list)

for dirpath, dirnames, filenames in os.walk(ROOT):
    if os.path.basename(dirpath) == "tags" and os.path.basename(os.path.dirname(dirpath)) == "_manifests":
        manifests_dir = os.path.dirname(dirpath)
        repo = os.path.relpath(os.path.dirname(manifests_dir), ROOT)
        for tag in dirnames:
            link_path = os.path.join(dirpath, tag, "current", "link")
            try:
                mtime = os.path.getmtime(link_path)
                with open(link_path, "r") as f:
                    digest = f.read().strip()
            except OSError:
                continue
            age_days = (now - mtime) / 86400
            tag_info[repo].append((tag, age_days, digest))

# --- simulate policy per repo ---
print(f"{'repo':45s} {'tags':>6s} {'expired':>8s} {'kept':>6s} {'reclaim(GB)':>12s}")

total_reclaim = 0.0
grand_total_size = 0.0
per_repo_results = []

for repo, tags in tag_info.items():
    pol = policy_for(repo)
    # most-recent-N floor (sort by age ascending = most recent first)
    sorted_tags = sorted(tags, key=lambda t: t[1])
    protected_recent = {t[0] for t in sorted_tags[: pol["keep"]]}

    kept_tags = []
    expired_tags = []
    for tag, age_days, digest in tags:
        if tag in protected_recent:
            kept_tags.append((tag, digest))
        elif pol["preserve"] and PRESERVE_RE.match(tag):
            kept_tags.append((tag, digest))
        elif age_days <= pol["expire_days"]:
            kept_tags.append((tag, digest))
        else:
            expired_tags.append((tag, digest))

    kept_digests = set()
    for _, digest in kept_tags:
        kept_digests |= manifest_digests(digest)

    expired_digests = set()
    for _, digest in expired_tags:
        expired_digests |= manifest_digests(digest)

    # reclaimable = referenced by an expired tag but NOT by any kept tag (within this repo)
    reclaimable = expired_digests - kept_digests
    reclaim_bytes = sum(blob_size(d) for d in reclaimable)
    reclaim_gb = reclaim_bytes / 1024 / 1024 / 1024

    all_digests = set()
    for _, _, digest in tags:
        all_digests |= manifest_digests(digest)
    repo_total_gb = sum(blob_size(d) for d in all_digests) / 1024 / 1024 / 1024

    total_reclaim += reclaim_gb
    grand_total_size += repo_total_gb
    per_repo_results.append((repo, len(tags), len(expired_tags), len(kept_tags), reclaim_gb, repo_total_gb))

per_repo_results.sort(key=lambda r: -r[4])
for repo, n, exp, kept, reclaim_gb, repo_gb in per_repo_results:
    print(f"{repo:45s} {n:6d} {exp:8d} {kept:6d} {reclaim_gb:12.2f}")

print()
print(f"Current total registry size (recomputed from manifests): {grand_total_size:.2f} GB")
print(f"TOTAL estimated reclaim if all proposed policies applied: {total_reclaim:.2f} GB "
      f"({100*total_reclaim/grand_total_size:.1f}% of current size)")
print()
print("Note: 'reclaim' here = blobs referenced ONLY by tags that would expire under the policy")
print("above (not shared with any tag that would be kept, within the same repo). Cross-repo")
print("sharing was separately confirmed negligible for the big repos in the earlier analysis.")
print("Preserve-regex matches (main/master/stable/latest/release-*/vX.Y.Z) are excluded from")
print("expiry wherever the policy applies it - if your real tags don't use these names, this")
print("estimate is accurate as computed; if some do, actual reclaim will be slightly lower.")
