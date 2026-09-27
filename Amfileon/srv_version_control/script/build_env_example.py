#!/usr/bin/env python3
"""
Builds a .env.example from an existing, real .env, by classifying each
KEY=VALUE pair the same way sanitize_service_files.py classifies extracted
vars during a normal compose-file conversion: the union of gitleaks/
trufflehog value-based scanning and the PASSWORD/SECRET/TOKEN/... key-name
heuristic (see classify_env_values). Secret-classified values are blanked
(KEY=), everything else keeps its real value -- config vars like hostnames/
ports are meant to be visible in the example file as a reference for anyone
reconstructing a working .env from scratch.

This exists because the normal per-service conversion workflow only ever
used sanitize_service_files.py's .env.additions output (real values, to
build the real .env) and never its .env.example.additions output (the
git-trackable companion) -- and by the time that gap was noticed, the
per-service compose file had already been converted to ${VAR} syntax, so
re-running the extractor against it finds nothing left to extract (every
value already starts with "${"). Re-running against the .pre-versioning-backup
would also just report every var as a CONFLICT (already in .env) and skip
producing .env.example.additions for exactly that reason. Working from the
real, already-built .env directly sidesteps all of that.

Usage:
  python3 build_env_example.py <path-to-.env>

Only ever prints key NAMES and which classification each got -- never a
value, matching every other script in this toolkit. Writes
<path-to-.env>.example.additions (real values for config keys, blanked for
secret keys) -- review it, then `cat` it into the real .env.example
yourself, same as sanitize_service_files.py's own .env.example.additions.
Purely additive: skips any key already present in an existing .env.example
next to the .env, never overwrites.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sanitize_service_files import classify_env_values, load_env_keys


def parse_env_file(path):
    pairs = []
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.lstrip().startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            pairs.append((k.strip(), v))
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('env_path')
    args = ap.parse_args()

    pairs = parse_env_file(args.env_path)
    if not pairs:
        print("no KEY=VALUE pairs found")
        return

    example_path = os.path.join(os.path.dirname(os.path.abspath(args.env_path)) or '.', '.env.example')
    existing_keys = load_env_keys(example_path) if os.path.isfile(example_path) else set()

    secret_keys = classify_env_values(pairs)

    out_path = args.env_path + '.example.additions'
    written = 0
    with open(out_path, 'w') as f:
        for k, v in pairs:
            if k in existing_keys:
                continue
            if k in secret_keys:
                f.write(f"{k}=\n")
            else:
                f.write(f"{k}={v}\n")
            written += 1

    print(f"wrote {out_path}  ({written} lines, review then cat >> .env.example)")
    for k, v in pairs:
        if k in existing_keys:
            print(f"  - {k}  (already in .env.example, skipped)")
            continue
        tag = "secret -> blanked" if k in secret_keys else "config -> real value kept"
        print(f"  - {k}  ({tag})")


if __name__ == '__main__':
    main()
