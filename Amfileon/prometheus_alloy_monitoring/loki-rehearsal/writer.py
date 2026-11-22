#!/usr/bin/env python3
"""writer <run> <seconds>: pushes numbered lines nonstop (10/s) and RETRIES each until Loki accepts it
(like Alloy/promtail). check <run>: are all numbers 0..N-1 in Loki?"""
import json, sys, time, urllib.request, urllib.parse
L = "http://localhost:3100"; run = sys.argv[2]
if sys.argv[1] == "writer":
    end, seq, retries = time.time() + float(sys.argv[3]), 0, 0
    while time.time() < end:
        body = json.dumps({"streams": [{"stream": {"container": "writer", "run": run, "job": "rehearsal"},
                "values": [[str(time.time_ns()), f"seq={seq}"]]}]}).encode()
        delay = 0.5
        while True:
            try:
                urllib.request.urlopen(urllib.request.Request(L + "/loki/api/v1/push", body, {"Content-Type": "application/json"}), timeout=5); break
            except Exception: retries += 1; time.sleep(delay); delay = min(delay * 2, 5)
        seq += 1; time.sleep(0.1)
    open(f"/tmp/writer-{run}.n", "w").write(str(seq)); print(f"writer {run}: sent {seq} lines, {retries} retries")
else:
    n = int(open(f"/tmp/writer-{run}.n").read()); now = time.time_ns(); got = set()
    q = urllib.parse.urlencode({"query": f'{{container="writer",run="{run}"}}', "start": str(now - 3600 * 10**9),
                                "end": str(now), "limit": 5000, "direction": "forward"})
    for s in json.load(urllib.request.urlopen(L + "/loki/api/v1/query_range?" + q))["data"]["result"]:
        got |= {int(v[1].split("=")[1]) for v in s["values"]}
    miss = sorted(set(range(n)) - got)
    print(f"run={run}: sent {n}, found {len(got)}, MISSING {len(miss)}" + (f" (seq {miss[0]}..{miss[-1]})" if miss else ""))
