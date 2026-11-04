#!/usr/bin/env python3
"""Compares source="dockprom" (separate exporter containers, today) with source="builtin" (Alloy's
built-in exporters) for every node_/container_ metric our dashboards and alert rules use.

    python3 compare.py [--prom http://localhost:19091] [--metrics used_metrics.txt]
"""
import argparse
import json
import pathlib
import urllib.parse
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--prom", default="http://localhost:19091")
ap.add_argument("--metrics", default=str(pathlib.Path(__file__).with_name("used_metrics.txt")))
args = ap.parse_args()

# labels that dashboards/rules select or group by
KEY_LABELS = ["mountpoint", "fstype", "device", "mode", "name", "interface", "id"]


def q(expr):
    url = f"{args.prom}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    return json.load(urllib.request.urlopen(url, timeout=60))["data"]["result"]


def keyset(metric, source):
    out = {}
    for r in q(f'{metric}{{source="{source}"}}'):
        k = tuple((l, r["metric"].get(l, "")) for l in KEY_LABELS if l in r["metric"])
        out[k] = float(r["value"][1])
    return out


problems = 0
for metric in [m for m in pathlib.Path(args.metrics).read_text().split() if m]:
    ref, cand = keyset(metric, "dockprom"), keyset(metric, "builtin")
    only_ref, only_cand = set(ref) - set(cand), set(cand) - set(ref)
    labels_ref = sorted({l for k in ref for l, _ in k})
    labels_cand = sorted({l for k in cand for l, _ in k})
    status = "OK"
    notes = []
    if not cand:
        status, notes = "MISSING", ["not produced by the built-in exporter"]
    else:
        if labels_ref != labels_cand:
            status = "DIFF"; notes.append(f"labels {labels_ref} vs {labels_cand}")
        if only_ref:
            status = "DIFF"; notes.append(f"{len(only_ref)} series only in dockprom, e.g. {dict(sorted(only_ref)[0])}")
        if only_cand:
            notes.append(f"{len(only_cand)} extra in builtin")
        # value check on common gauges (counters differ by start time; compare only non-_total)
        common = set(ref) & set(cand)
        if common and not metric.endswith("_total"):
            worst = max(abs(ref[k] - cand[k]) / (abs(ref[k]) or 1) for k in common)
            if worst > 0.05:
                status = "DIFF"; notes.append(f"values differ up to {worst:.0%}")
    if status != "OK":
        problems += 1
    print(f"{status:8} {metric:42} dockprom={len(ref):4}  builtin={len(cand):4}  {'; '.join(notes)}")
print(f"\n{problems} metric(s) need attention")
