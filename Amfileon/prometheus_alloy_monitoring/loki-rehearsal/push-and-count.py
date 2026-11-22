#!/usr/bin/env python3
"""push: writes 20 lines each into streams aged 100d/95d/60d/1d/0d.   count: lines found per stream."""
import json, sys, time, urllib.request, urllib.parse
L="http://localhost:3100"; AGES=[100,95,60,1,0]; NOW=time.time()
def ts(age, i): return NOW - age*86400 - 3600 + i*60
if sys.argv[1]=="push":
    for a in AGES:
        vals=[[str(int(ts(a,i)*1e9)), f"rehearsal line {i} age={a}d"] for i in range(20)]
        body=json.dumps({"streams":[{"stream":{"container":"rehearsal","age":f"{a}d"},"values":vals}]}).encode()
        r=urllib.request.urlopen(urllib.request.Request(L+"/loki/api/v1/push",body,{"Content-Type":"application/json"}))
        print(f"pushed age={a}d -> {r.status}")
else:
    for a in AGES:
        q=urllib.parse.urlencode({"query":f'count_over_time({{container="rehearsal",age="{a}d"}}[3h])',
            "start":str(int((ts(a,0)-600)*1e9)),"end":str(int((ts(a,19)+7200)*1e9)),"step":"3h"})
        d=json.load(urllib.request.urlopen(L+"/loki/api/v1/query_range?"+q))
        n=max((float(v[1]) for r in d["data"]["result"] for v in r["values"]),default=0)
        print(f"age={a:>3}d  lines={int(n)}")
