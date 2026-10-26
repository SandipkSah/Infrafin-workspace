#!/usr/bin/env python3
"""Runs every panel query of every dashboard through the local Grafana's datasource and reports
panels that return no data or an error.

    python3 check_dashboards.py [--ds prom-db1] [--host db1] [--database db1]

Variables are substituted with concrete values; $__rate_interval → 1m, $__range → 1h.
"""
import argparse
import base64
import json
import pathlib
import urllib.parse
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--grafana", default="http://localhost:3001")
ap.add_argument("--auth", default="admin:admin")
ap.add_argument("--ds", default="prom-db1")
ap.add_argument("--host", default="db1")
ap.add_argument("--database", default="db1")
args = ap.parse_args()
AUTH = "Basic " + base64.b64encode(args.auth.encode()).decode()


def query(expr, instant, ds):
    for k, v in {"$__rate_interval": "1m", "$__range": "1h", "$host": args.host,
                 "$database": args.database}.items():
        expr = expr.replace(k, v)
    path = "query" if instant else "query_range"
    params = {"query": expr}
    if not instant:
        import time
        now = int(time.time())
        params.update(start=now - 3600, end=now, step=60)
    url = (f"{args.grafana}/api/datasources/proxy/uid/{ds}/api/v1/{path}?"
           + urllib.parse.urlencode(params))
    req = urllib.request.Request(url, headers={"Authorization": AUTH})
    try:
        body = json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        return "ERROR", e.read().decode()[:200]
    if body.get("status") != "success":
        return "ERROR", str(body)[:200]
    n = len(body["data"]["result"])
    return ("ok" if n else "EMPTY"), f"{n} series"


def panels(d):
    for p in d["panels"]:
        yield p
        yield from p.get("panels", [])


bad = 0
for f in sorted(pathlib.Path(__file__).parent.joinpath("dashboards").glob("*.json")):
    d = json.loads(f.read_text())
    print(f"\n{d['title']}")
    for p in panels(d):
        for t in p.get("targets", []):
            uid = (t.get("datasource") or {}).get("uid", "${ds}")
            ds = args.ds if uid == "${ds}" else uid          # pinned panels keep their own datasource
            status, info = query(t["expr"], t.get("instant", False), ds)
            mark = "  " if status == "ok" else "!!"
            if status != "ok":
                bad += 1
            print(f"  {mark} {status:5} {p['title'][:48]:48} [{t['refId']}] {info}")
print(f"\n{bad} queries without data or with errors (ds={args.ds}, host={args.host}, database={args.database})")
