#!/usr/bin/env python3
"""push <run> [n]: n lines with timestamps of the last minutes, label run=<run>.   count <run>: lines Loki finds."""
import json, sys, time, urllib.request, urllib.parse
L = "http://localhost:3100"
cmd, run = sys.argv[1], sys.argv[2]
if cmd == "push":
    n, now = int(sys.argv[3]) if len(sys.argv) > 3 else 200, time.time()
    vals = [[str(int((now - (n - i)) * 1e9)), f"recent line {i} run={run}"] for i in range(n)]
    body = json.dumps({"streams": [{"stream": {"container": "recent", "run": run}, "values": vals}]}).encode()
    urllib.request.urlopen(urllib.request.Request(L + "/loki/api/v1/push", body, {"Content-Type": "application/json"}))
    print(f"pushed {n} lines run={run}")
else:
    now = time.time()
    q = urllib.parse.urlencode({"query": f'sum(count_over_time({{container="recent",run="{run}"}}[2h]))',
                                "time": str(int(now * 1e9))})
    d = json.load(urllib.request.urlopen(L + "/loki/api/v1/query?" + q))
    print(f"run={run}  lines found={int(float(d['data']['result'][0]['value'][1])) if d['data']['result'] else 0}")
