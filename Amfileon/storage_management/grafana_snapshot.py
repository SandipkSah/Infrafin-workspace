#!/usr/bin/env python3
"""Read-only health snapshot of the fleet via the local Grafana (Prometheus data source).

Run on the Mac where Grafana is reachable at localhost:3001:
    python3 storage_management/grafana_snapshot.py

Reads the token from $AMF_GRAFANA_TOKEN or the AMF_GRAFANA_TOKEN= line in ~/.zshrc.
Only issues GET requests (Prometheus instant queries); writes the result to
storage_management/grafana-snapshot.txt. The token is never printed.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("GRAFANA_URL", "http://localhost:3001")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "grafana-snapshot.txt")
FS = 'fstype!~"tmpfs|overlay|squashfs|nsfs|fuse.*",mountpoint!~"/(run|boot|snap|var/lib/docker).*"'

QUERIES = [
    ("Disk usage % (avail-based, like Grafana/df)",
     f'round(100 * (1 - node_filesystem_avail_bytes{{{FS}}} / node_filesystem_size_bytes{{{FS}}}), 0.1)'),
    ("Disk free (GB)",
     f'round(node_filesystem_avail_bytes{{{FS}}} / 1e9)'),
    ("Free-space change per day over 7d (GB/day, negative = filling)",
     f'round(deriv(node_filesystem_avail_bytes{{{FS}}}[7d]) * 86400 / 1e9, 0.1)'),
    ("Days until full at the 7d rate (only filling mounts)",
     f'round(node_filesystem_avail_bytes{{{FS}}} / (-deriv(node_filesystem_avail_bytes{{{FS}}}[7d]) * 86400) > 0, 0.1)'),
    ("Free-space change over 30d (GB, negative = filled)",
     f'round((node_filesystem_avail_bytes{{{FS}}} - node_filesystem_avail_bytes{{{FS}}} offset 30d) / 1e9)'),
    ("Inode usage %",
     f'round(100 * (1 - node_filesystem_files_free{{{FS}}} / node_filesystem_files{{{FS}}}), 0.1)'),
    ("Zombie processes", 'node_processes_state{state="Z"}'),
    ("Processes / PID limit", 'node_processes_pids'),
    ("PID limit", 'node_processes_max_processes'),
    ("Load15", 'node_load15'),
    ("CPU count", 'count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})'),
    ("Memory used %",
     'round(100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), 0.1)'),
    ("Swap used %",
     'round(100 * (1 - node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes), 0.1)'),
    ("OOM kills in 7d", 'increase(node_vmstat_oom_kill[7d])'),
    ("Disk busy % (1h avg, top 10)",
     'topk(10, round(100 * rate(node_disk_io_time_seconds_total[1h]), 0.1))'),
    ("Scrape targets down", 'up == 0'),
    ("Top 10 containers by memory (GB, cAdvisor)",
     'topk(10, round(container_memory_working_set_bytes{name!=""} / 1e9, 0.01))'),
    ("Top 10 containers by CPU cores (1h, cAdvisor)",
     'topk(10, round(rate(container_cpu_usage_seconds_total{name!=""}[1h]), 0.01))'),
]


def token():
    t = os.environ.get("AMF_GRAFANA_TOKEN")
    if t:
        return t
    try:
        for line in open(os.path.expanduser("~/.zshrc")):
            m = re.match(r'\s*(?:export\s+)?AMF_GRAFANA_TOKEN=["\']?([^"\'\s]+)', line)
            if m:
                return m.group(1)
    except OSError:
        pass
    sys.exit("AMF_GRAFANA_TOKEN not found in env or ~/.zshrc")


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # localhost: no proxy
HEADERS = {"Authorization": f"Bearer {token()}", "Accept": "application/json"}


def get(path, params=None):
    url = GRAFANA + path + ("?" + urllib.parse.urlencode(params) if params else "")
    with opener.open(urllib.request.Request(url, headers=HEADERS), timeout=60) as r:
        return json.load(r)


def label(metric):
    # print every label (host names live in a non-standard label here; instance is the same for all hosts)
    m = {k: v for k, v in metric.items() if k not in ("__name__", "job", "instance", "fstype")}
    return " ".join(f"{k}={v}" for k, v in sorted(m.items())) or "-"


def main():
    settings = get("/api/frontend/settings")
    proms = {n: d for n, d in settings.get("datasources", {}).items() if d.get("type") == "prometheus"}
    if not proms:
        sys.exit("No Prometheus data source visible to this token")
    lines = [f"Grafana: {GRAFANA}", f"Prometheus data sources: {', '.join(proms)}", ""]
    for ds_name, ds in proms.items():
        lines.append(f"################ {ds_name} ################")
        for title, q in QUERIES:
            lines.append(f"\n== {title}")
            try:
                res = get(f"/api/datasources/proxy/uid/{ds['uid']}/api/v1/query", {"query": q})
                rows = res.get("data", {}).get("result", [])
                if not rows:
                    lines.append("   (no data)")
                for r in sorted(rows, key=lambda r: label(r["metric"]))[:60]:
                    lines.append(f"   {label(r['metric']):<90} {r['value'][1]}")
            except Exception as e:  # keep going on missing metrics / permissions
                lines.append(f"   ERROR: {e}")
        lines.append("")
    open(OUT, "w").write("\n".join(lines) + "\n")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
