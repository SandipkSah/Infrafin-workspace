#!/usr/bin/env python3
"""Generates the Amfileon Grafana dashboards (dashboards as code).

    python3 gen_dashboards.py          # writes dashboards/*.json

Edit this file, not the dashboards in the Grafana UI (they are provisioned read-only).
The same JSON files are later provisioned in dockprom's Grafana on db1.

Design rules (dataviz method):
- every host has ONE fixed colour on every chart (colour follows the entity, never its rank)
- status colours (good/warning/serious/critical) are only used for thresholds/states
- one y-axis per chart; no dual axes
- a datasource drop-down (Prometheus-db1 / Prometheus-db2) on every dashboard
"""
import json
import pathlib

OUT = pathlib.Path(__file__).parent / "dashboards"

# ── palette (reference categorical order, light/dark-safe; status palette fixed) ──────────────
HOST_COLORS = {          # categorical slots 1..6, fixed per host
    "db1": "#2a78d6", "db2": "#eb6834", "cpu1": "#1baf7a",
    "cpu2": "#eda100", "gpu1": "#e87ba4", "prod3": "#008300",
}
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
GOOD, WARNING, SERIOUS, CRITICAL = "#0ca30c", "#fab219", "#ec835a", "#d03b3b"

DS = {"type": "prometheus", "uid": "${ds}"}



# Same navigation bar on every dashboard (keeps the selected time range and Prometheus).
NAV = [("Fleet", "amf-fleet"), ("Hosts", "amf-host"), ("Traffic", "amf-traffic"),
       ("PostgreSQL", "amf-postgres"), ("Certificates", "amf-certificates"), ("Monitoring", "amf-monitoring")]
NAV_LINKS = [{"title": t, "type": "link", "url": f"/d/{uid}?${{__url_time_range}}&var-ds=${{ds}}",
              "icon": "dashboard", "asDropdown": False, "targetBlank": False, "keepTime": False,
              "includeVars": False, "tooltip": ""} for t, uid in NAV]

# ── building blocks ───────────────────────────────────────────────────────────────────────────
class Grid:
    """Hands out panel ids and grid positions row by row (24 columns wide)."""

    def __init__(self):
        self.id, self.x, self.y, self.row_h = 0, 0, 0, 0

    def place(self, w, h):
        if self.x + w > 24:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        self.id += 1
        return self.id, pos

    def newline(self):
        if self.x:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0


def targets(*qs, instant=False, fmt="time_series"):
    out = []
    for i, q in enumerate(qs):
        expr, legend = (q if isinstance(q, tuple) else (q, ""))
        t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": chr(65 + i),
             "range": not instant, "instant": instant, "format": fmt}
        out.append(t)
    return out


def thresholds(*steps):
    """steps: (value or None, color) ..."""
    return {"mode": "absolute", "steps": [{"value": v, "color": c} for v, c in steps]}


def host_overrides(field_name_suffix=""):
    """Pin each host's colour wherever a series/field is named after the host."""
    return [{"matcher": {"id": "byName", "options": h + field_name_suffix},
             "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
            for h, c in HOST_COLORS.items()]


def timeseries(g, title, tgts, unit, w=12, h=8, desc="", stack=False, minv=None, maxv=None,
               overrides=None, legend_calcs=("mean", "max", "lastNotNull"), fill=10,
               thresh=None, thresh_style="line+area"):
    if w < 12 and h == 8:
        h = 10   # room for the legend underneath
    pid, pos = g.place(w, h)
    defaults = {
        "unit": unit,
        "color": {"mode": "palette-classic"},
        "custom": {
            "lineWidth": 2, "fillOpacity": fill, "showPoints": "never", "spanNulls": False,
            "stacking": {"mode": "normal" if stack else "none"},
            "axisSoftMin": 0, "gradientMode": "none",
            "thresholdsStyle": {"mode": thresh_style if thresh else "off"},
        },
    }
    if minv is not None:
        defaults["min"] = minv
    if maxv is not None:
        defaults["max"] = maxv
    if thresh:
        defaults["thresholds"] = thresh
    return {
        "id": pid, "type": "timeseries", "title": title, "description": desc, "datasource": DS,
        "gridPos": pos, "targets": tgts,
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": {
            # narrow panels: legend underneath, so the plot keeps its width
            "legend": {"displayMode": "table", "placement": "right" if w >= 12 else "bottom", "showLegend": True,
                       "calcs": list(legend_calcs), "sortBy": "Max", "sortDesc": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }


def stat(g, title, tgts, unit="none", w=4, h=4, desc="", thresh=None, mappings=None,
         color_mode="background", text_mode="auto", decimals=None, calc="lastNotNull",
         orientation="auto", overrides=None):
    pid, pos = g.place(w, h)
    defaults = {"unit": unit, "color": {"mode": "thresholds"},
                "thresholds": thresh or thresholds((None, "#5b6b7f")),
                "mappings": mappings or []}
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": pid, "type": "stat", "title": title, "description": desc, "datasource": DS,
        "gridPos": pos, "targets": tgts,
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": {"reduceOptions": {"calcs": [calc], "fields": "", "values": False},
                    "colorMode": color_mode, "graphMode": "none", "textMode": text_mode,
                    "justifyMode": "center", "orientation": orientation, "wideLayout": True,
                    "showPercentChange": False},
    }


def bargauge(g, title, tgts, unit, w=12, h=8, desc="", thresh=None, minv=0, maxv=None):
    pid, pos = g.place(w, h)
    defaults = {"unit": unit, "min": minv, "color": {"mode": "thresholds"},
                "thresholds": thresh or thresholds((None, SERIES[0]))}
    if maxv is not None:
        defaults["max"] = maxv
    return {
        "id": pid, "type": "bargauge", "title": title, "description": desc, "datasource": DS,
        "gridPos": pos, "targets": tgts,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": True,
                    "valueMode": "text", "namePlacement": "left", "sizing": "auto",
                    "minVizHeight": 16, "maxVizHeight": 24,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
    }


def table(g, title, tgts, w=24, h=8, desc="", transformations=None, overrides=None,
          defaults=None, sort=None):
    pid, pos = g.place(w, h)
    return {
        "id": pid, "type": "table", "title": title, "description": desc, "datasource": DS,
        "gridPos": pos, "targets": tgts, "transformations": transformations or [],
        "fieldConfig": {"defaults": defaults or {"custom": {"align": "auto"}},
                        "overrides": overrides or []},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": sort or [], "footer": {"show": False}},
    }


def text(g, content, w=24, h=2):
    pid, pos = g.place(w, h)
    return {"id": pid, "type": "text", "title": "", "gridPos": pos, "transparent": True,
            "options": {"mode": "markdown", "content": content}}


def row(g, title, collapsed=False, panels=None):
    g.newline()
    pid, pos = g.place(24, 1)
    g.newline()
    return {"id": pid, "type": "row", "title": title, "gridPos": pos, "collapsed": collapsed,
            "panels": panels or []}


def ds_var():
    return {"name": "ds", "label": "Prometheus", "type": "datasource", "query": "prometheus",
            "regex": "Prometheus-db.*", "current": {"text": "Prometheus-db1", "value": "prom-db1"},
            "hide": 0, "refresh": 1, "includeAll": False, "multi": False}


def query_var(name, label, query, include_all=False, multi=False):
    return {"name": name, "label": label, "type": "query", "datasource": DS,
            "query": {"query": query, "refId": "var"}, "definition": query,
            "refresh": 2, "sort": 1, "hide": 0, "includeAll": include_all, "multi": multi}


def dashboard(uid, title, panels, variables, desc, refresh="1m", time_from="now-6h", tags=()):
    return {
        "uid": uid, "title": title, "description": desc, "tags": list(tags),
        "timezone": "browser", "schemaVersion": 39, "version": 1, "editable": False,
        "graphTooltip": 1,  # shared crosshair across panels
        "refresh": refresh, "time": {"from": time_from, "to": "now"},
        "templating": {"list": variables}, "panels": panels,
        "links": NAV_LINKS,
    }


# ── shared PromQL ─────────────────────────────────────────────────────────────────────────────
CORES = 'count by (host) (node_cpu_seconds_total{job="nodeexporter", mode="idle"})'
CPU_BUSY = ('100 * (1 - avg by (host) (rate(node_cpu_seconds_total{job="nodeexporter", '
            'mode="idle"}[$__rate_interval])))')
MEM_USED = ('100 * (1 - max by (host) (node_memory_MemAvailable_bytes{job="nodeexporter"}) '
            '/ max by (host) (node_memory_MemTotal_bytes{job="nodeexporter"}))')
REAL_FS = 'job="nodeexporter", fstype=~"ext4|xfs|btrfs|zfs", mountpoint!~"/boot.*"'
DISK_USED = (f'100 * (1 - node_filesystem_avail_bytes{{{REAL_FS}}} '
             f'/ node_filesystem_size_bytes{{{REAL_FS}}})')
PCT_THRESH = thresholds((None, GOOD), (80, WARNING), (90, CRITICAL))


# ── 1. Fleet overview ─────────────────────────────────────────────────────────────────────────
def fleet():
    g = Grid()
    p = [
        stat(g, "Hosts reachable", targets(('up{job="host-alive"}', "{{host}}")), w=14, h=4,
             desc="db1 checks every host's Alloy agent every 15 s (host-alive). DOWN = host or agent unreachable → HostDown alert after 2 min.",
             thresh=thresholds((None, CRITICAL), (1, GOOD)), text_mode="value_and_name",
             mappings=[{"type": "value", "options": {"0": {"text": "DOWN", "color": CRITICAL},
                                                     "1": {"text": "UP", "color": GOOD}}}]),
        stat(g, "Alerts firing", targets('count(ALERTS{alertstate="firing", alertname!="Watchdog"}) or vector(0)'),
             w=5, h=4, desc="Firing alerts (Watchdog excluded). Details: 'Monitoring health' dashboard.",
             thresh=thresholds((None, GOOD), (1, CRITICAL))),
        stat(g, "Prometheus up (db1 / db2)", targets(('up{job=~"prometheus-db.*"}', "{{host}}")), w=5, h=4,
             desc="Both Prometheus copies, as seen by db1.", text_mode="value_and_name",
             thresh=thresholds((None, CRITICAL), (1, GOOD)),
             mappings=[{"type": "value", "options": {"0": {"text": "DOWN", "color": CRITICAL},
                                                     "1": {"text": "UP", "color": GOOD}}}]),
    ]
    p.append(table(
        g, "Hosts — now",
        targets((CPU_BUSY, "cpu"), (MEM_USED, "mem"),
                (f'max by (host) ({DISK_USED})', "disk"),
                (f'max by (host) (node_load1{{job="nodeexporter"}}) / {CORES}', "load"),
                (CORES, "cores"),
                ('max by (host) (node_memory_MemTotal_bytes{job="nodeexporter"})', "ram"),
                ('time() - max by (host) (node_boot_time_seconds{job="nodeexporter"})', "uptime"),
                instant=True, fmt="table"),
        h=8, desc="One row per host. Disk = fullest real filesystem on that host (see 'Disk usage by mount').",
        transformations=[
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {
                "excludeByName": {"Time": True},
                "indexByName": {"host": 0, "Value #A": 1, "Value #B": 2, "Value #C": 3,
                                "Value #D": 4, "Value #E": 5, "Value #F": 6, "Value #G": 7},
                "renameByName": {"host": "Host", "Value #A": "CPU busy", "Value #B": "Memory used",
                                 "Value #C": "Fullest disk", "Value #D": "Load / core",
                                 "Value #E": "Cores", "Value #F": "RAM", "Value #G": "Uptime"}}},
        ],
        sort=[{"displayName": "Host", "desc": False}],
        overrides=[
            *[{"matcher": {"id": "byName", "options": n},
               "properties": [{"id": "unit", "value": "percent"}, {"id": "decimals", "value": 1},
                              {"id": "max", "value": 100}, {"id": "min", "value": 0},
                              {"id": "thresholds", "value": PCT_THRESH},
                              {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}]}
              for n in ("CPU busy", "Memory used", "Fullest disk")],
            {"matcher": {"id": "byName", "options": "Load / core"},
             "properties": [{"id": "decimals", "value": 2},
                            {"id": "thresholds", "value": thresholds((None, GOOD), (1, WARNING), (2, CRITICAL))},
                            {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
            {"matcher": {"id": "byName", "options": "RAM"}, "properties": [{"id": "unit", "value": "bytes"}]},
            {"matcher": {"id": "byName", "options": "Uptime"}, "properties": [{"id": "unit", "value": "dtdurations"}]},
            {"matcher": {"id": "byName", "options": "Host"},
             "properties": [{"id": "links", "value": [{"title": "Host detail",
                             "url": "/d/amf-host?var-host=${__value.raw}&${__url_time_range}&var-ds=${ds}"}]}]},
        ]))
    p.append(row(g, "Trends"))
    p.append(timeseries(g, "CPU busy (% of all cores)", targets((CPU_BUSY, "{{host}}")), "percent",
                        minv=0, maxv=100, overrides=host_overrides(), fill=0))
    p.append(timeseries(g, "Memory used (% of RAM)", targets((MEM_USED, "{{host}}")), "percent",
                        minv=0, maxv=100, overrides=host_overrides(), fill=0))
    p.append(timeseries(g, "Load per core (1 min)",
                        targets((f'max by (host) (node_load1{{job="nodeexporter"}}) / {CORES}', "{{host}}")),
                        "none", overrides=host_overrides(), fill=0,
                        desc="Load average divided by core count: above 1 means work is queuing."))
    p.append(bargauge(g, "Disk usage by mount (fullest first)",
                      targets((f"sort_desc({DISK_USED})", "{{host}}  {{mountpoint}}"), instant=True),
                      "percent", w=24, h=11, maxv=100, thresh=PCT_THRESH,
                      desc="Real filesystems only (ext4/xfs), /boot excluded. Network mounts are shown on the host that owns the disk. HostDiskAlmostFull fires above 90 %."))
    return dashboard("amf-fleet", "Fleet overview", p, [ds_var()],
                     "All Amfileon hosts at a glance.", tags=("overview",))


# ── 2. Host detail ────────────────────────────────────────────────────────────────────────────
def host():
    g = Grid()
    H = 'host="$host"'
    p = [
        stat(g, "CPU busy", targets(CPU_BUSY.replace("job=\"nodeexporter\",", f'job="nodeexporter", {H},')),
             "percent", w=4, decimals=1, thresh=PCT_THRESH),
        stat(g, "Memory used", targets(MEM_USED.replace('{job="nodeexporter"}', f'{{job="nodeexporter", {H}}}')),
             "percent", w=4, decimals=1, thresh=PCT_THRESH),
        stat(g, "Fullest disk", targets(f'max({DISK_USED.replace(REAL_FS, REAL_FS + ", " + H)})'),
             "percent", w=4, decimals=1, thresh=PCT_THRESH),
        stat(g, "Cores", targets(f'count(node_cpu_seconds_total{{job="nodeexporter", {H}, mode="idle"}})'), w=3,
             color_mode="none"),
        stat(g, "RAM", targets(f'max(node_memory_MemTotal_bytes{{job="nodeexporter", {H}}})'), "bytes", w=3,
             color_mode="none"),
        stat(g, "Containers", targets(f'count(container_memory_working_set_bytes{{job="cadvisor", {H}, name!=""}})'),
             w=3, color_mode="none"),
        stat(g, "Uptime", targets(f'time() - max(node_boot_time_seconds{{job="nodeexporter", {H}}})'),
             "dtdurations", w=3, color_mode="none"),
    ]
    p.append(row(g, "CPU & memory"))
    p.append(timeseries(
        g, "CPU by mode (% of all cores)",
        targets((f'100 * sum by (mode) (rate(node_cpu_seconds_total{{job="nodeexporter", {H}, mode!="idle"}}[$__rate_interval])) '
                 f'/ scalar(count(node_cpu_seconds_total{{job="nodeexporter", {H}, mode="idle"}}))', "{{mode}}")),
        "percent", stack=True, minv=0, fill=40, legend_calcs=("mean", "max"),
        desc="Stacked: the top of the stack is total CPU busy. iowait = waiting on disk."))
    p.append(timeseries(
        g, "Memory",
        targets((f'max(node_memory_MemTotal_bytes{{job="nodeexporter", {H}}}) - max(node_memory_MemAvailable_bytes{{job="nodeexporter", {H}}})', "used"),
                (f'max(node_memory_Buffers_bytes{{job="nodeexporter", {H}}}) + max(node_memory_Cached_bytes{{job="nodeexporter", {H}}})', "buffers + cache (reclaimable)"),
                (f'max(node_memory_MemAvailable_bytes{{job="nodeexporter", {H}}})', "available")),
        "bytes", minv=0, fill=0,
        desc="'used' excludes reclaimable cache; 'available' is what new work can still get."))
    p.append(row(g, "Disks"))
    fs_sel = REAL_FS + ", " + H
    p.append(table(
        g, "Filesystems",
        targets((f'max by (mountpoint, device) (node_filesystem_size_bytes{{{fs_sel}}})', ""),
                (f'max by (mountpoint, device) (node_filesystem_size_bytes{{{fs_sel}}} - node_filesystem_avail_bytes{{{fs_sel}}})', ""),
                (f'max by (mountpoint, device) (node_filesystem_avail_bytes{{{fs_sel}}})', ""),
                (f'max by (mountpoint, device) ({DISK_USED.replace(REAL_FS, fs_sel)})', ""),
                instant=True, fmt="table"),
        w=12, h=8,
        transformations=[{"id": "merge", "options": {}},
                         {"id": "organize", "options": {
                             "excludeByName": {"Time": True},
                             "indexByName": {"mountpoint": 0, "device": 1, "Value #A": 2, "Value #B": 3, "Value #C": 4, "Value #D": 5},
                             "renameByName": {"mountpoint": "Mount", "device": "Device", "Value #A": "Size",
                                              "Value #B": "Used", "Value #C": "Free", "Value #D": "Use %"}}}],
        sort=[{"displayName": "Use %", "desc": True}],
        overrides=[{"matcher": {"id": "byName", "options": n},
                    "properties": [{"id": "unit", "value": "bytes"}, {"id": "custom.width", "value": 85}]}
                   for n in ("Size", "Used", "Free")] + [
            {"matcher": {"id": "byName", "options": "Mount"}, "properties": [{"id": "custom.width", "value": 90}]},
            {"matcher": {"id": "byName", "options": "Device"}, "properties": [{"id": "custom.width", "value": 120}]},
            {"matcher": {"id": "byName", "options": "Use %"},
             "properties": [{"id": "unit", "value": "percent"}, {"id": "decimals", "value": 1},
                            {"id": "min", "value": 0}, {"id": "max", "value": 100},
                            {"id": "thresholds", "value": PCT_THRESH},
                            {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}]}]))
    md = f'job="nodeexporter", {H}, device=~"md[0-9]+"'
    p.append(timeseries(
        g, "Disk throughput (RAID arrays)",
        targets((f'sum(rate(node_disk_read_bytes_total{{{md}}}[$__rate_interval]))', "read"),
                (f'sum(rate(node_disk_written_bytes_total{{{md}}}[$__rate_interval]))', "write")),
        "Bps", w=12, h=8, minv=0, fill=0,
        overrides=[{"matcher": {"id": "byName", "options": "read"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": SERIES[0]}}]},
                   {"matcher": {"id": "byName", "options": "write"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": SERIES[1]}}]}],
        desc="All md* RAID devices together (partitions excluded to avoid double counting)."))
    p.append(row(g, "Containers (cAdvisor)"))
    c = f'job="cadvisor", {H}, name!=""'
    p.append(bargauge(g, "Top 10 containers — CPU now (cores)",
                      targets((f'topk(10, sum by (name) (rate(container_cpu_usage_seconds_total{{{c}}}[5m])))', "{{name}}"), instant=True),
                      "none", w=12, h=9))
    p.append(bargauge(g, "Top 10 containers — memory now",
                      targets((f'topk(10, sum by (name) (container_memory_working_set_bytes{{{c}}}))', "{{name}}"), instant=True),
                      "bytes", w=12, h=9))
    p.append(timeseries(g, "Container CPU over time (top 5 by average)",
                        targets((f'sum by (name) (rate(container_cpu_usage_seconds_total{{{c}}}[$__rate_interval])) '
                                 f'and on (name) topk(5, avg_over_time(sum by (name) (rate(container_cpu_usage_seconds_total{{{c}}}[5m]))[$__range:5m] @ end()))', "{{name}}")),
                        "none", w=24, h=8, minv=0, fill=0,
                        desc="Cores used by the five containers with the highest average CPU over the selected time range (chosen once, at the end of the range)."))
    p.append(row(g, "Power (scaphandre — db2, prod3)", collapsed=True, panels=[
        timeseries(Grid(), "Host power draw", targets((f'scaph_host_power_microwatts{{{H}}} / 1e6', "host")),
                   "watt", w=24, h=8, minv=0, fill=10, desc="Measured by scaphandre via RAPL. Empty on hosts without scaphandre data."),
    ]))
    gpu = f'{H}, job="nvidia_dcg_export"'
    gg = Grid()
    gg.y = 100
    p.append(row(g, "GPU (gpu1)", collapsed=True, panels=[
        timeseries(gg, "GPU utilisation", targets((f'DCGM_FI_DEV_GPU_UTIL{{{gpu}}}', "GPU {{gpu}} {{modelName}}")),
                   "percent", w=12, minv=0, maxv=100, fill=10),
        timeseries(gg, "GPU memory used", targets((f'DCGM_FI_DEV_FB_USED{{{gpu}}} * 1024 * 1024', "used"),
                                                  (f'(DCGM_FI_DEV_FB_USED{{{gpu}}} + DCGM_FI_DEV_FB_FREE{{{gpu}}}) * 1024 * 1024', "total")),
                   "bytes", w=12, minv=0, fill=0),
        timeseries(gg, "GPU temperature", targets((f'DCGM_FI_DEV_GPU_TEMP{{{gpu}}}', "GPU {{gpu}}")), "celsius", w=12, fill=0,
                   thresh=thresholds((None, "transparent"), (83, WARNING), (90, CRITICAL)), thresh_style="dashed"),
        timeseries(gg, "GPU power", targets((f'DCGM_FI_DEV_POWER_USAGE{{{gpu}}}', "GPU {{gpu}}")), "watt", w=12, minv=0, fill=10),
    ]))
    return dashboard("amf-host", "Host detail", p,
                     [ds_var(), query_var("host", "Host", 'label_values(up{job="nodeexporter"}, host)')],
                     "Everything about one host. Pick the host at the top.", tags=("host",))


# ── 3. PostgreSQL ─────────────────────────────────────────────────────────────────────────────
def postgres():
    g = Grid()
    D = 'database="$database"'
    p = [
        stat(g, "Exporter / server up", targets(f'max(pg_up{{{D}}})'), w=4,
             thresh=thresholds((None, CRITICAL), (1, GOOD)),
             mappings=[{"type": "value", "options": {"0": {"text": "DOWN", "color": CRITICAL},
                                                     "1": {"text": "UP", "color": GOOD}}}]),
        stat(g, "Connections used", targets(f'100 * sum(pg_stat_database_numbackends{{{D}}}) / max(pg_settings_max_connections{{{D}}})'),
             "percent", w=5, decimals=0, thresh=PCT_THRESH, desc="Backends / max_connections."),
        stat(g, "Cache hit ratio", targets(
            f'100 * sum(rate(pg_stat_database_blks_hit{{{D}}}[$__range])) / '
            f'(sum(rate(pg_stat_database_blks_hit{{{D}}}[$__range])) + sum(rate(pg_stat_database_blks_read{{{D}}}[$__range])))'),
            "percent", w=5, decimals=1,
            thresh=thresholds((None, WARNING), (99, GOOD)),
            desc="Share of block reads served from shared_buffers over the selected range. The 99 % rule of thumb is for transactional databases; very large analytical databases (e.g. 'fundamental', several TiB) are naturally lower, and Postgres counts reads served by the OS file cache as misses too."),
        stat(g, "Total size", targets(f'sum(pg_database_size_bytes{{{D}}})'), "bytes", w=5, color_mode="none"),
        stat(g, "Deadlocks (range)", targets(f'sum(increase(pg_stat_database_deadlocks{{{D}}}[$__range]))'), w=5,
             decimals=0, thresh=thresholds((None, GOOD), (1, WARNING))),
    ]
    p.append(row(g, "Activity"))
    p.append(timeseries(g, "Transactions per second",
                        targets((f'sum(rate(pg_stat_database_xact_commit{{{D}}}[$__rate_interval]))', "commits"),
                                (f'sum(rate(pg_stat_database_xact_rollback{{{D}}}[$__rate_interval]))', "rollbacks")),
                        "ops", minv=0, fill=0,
                        overrides=[{"matcher": {"id": "byName", "options": "commits"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": SERIES[0]}}]},
                                   {"matcher": {"id": "byName", "options": "rollbacks"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": SERIES[1]}}]}]))
    p.append(timeseries(g, "Rows read per second",
                        targets(*[(f'sum(rate(pg_stat_database_tup_{k}{{{D}}}[$__rate_interval]))', k)
                                  for k in ("fetched", "returned")]),
                        "ops", w=6, minv=0, fill=0,
                        desc="fetched = rows read via index scans; returned = rows read by sequential scans."))
    p.append(timeseries(g, "Rows written per second",
                        targets(*[(f'sum(rate(pg_stat_database_tup_{k}{{{D}}}[$__rate_interval]))', k)
                                  for k in ("inserted", "updated", "deleted")]),
                        "ops", w=6, minv=0, fill=0, legend_calcs=("mean", "max")))
    p.append(timeseries(g, "Connections by database (top 8)",
                        targets((f'sum by (datname) (pg_stat_database_numbackends{{{D}}}) and on (datname) '
                                 f'topk(8, max_over_time(sum by (datname) (pg_stat_database_numbackends{{{D}}})[$__range:1m] @ end()))', "{{datname}}")),
                        "none", minv=0, fill=0))
    p.append(timeseries(g, "Temp files written",
                        targets((f'sum(rate(pg_stat_database_temp_bytes{{{D}}}[$__rate_interval]))', "temp bytes")),
                        "Bps", minv=0, fill=10,
                        desc="Queries spilling to disk (sorts/hashes bigger than work_mem)."))
    p.append(row(g, "Size & replication"))
    p.append(bargauge(g, "Database sizes (top 12)",
                      targets((f'sort_desc(topk(12, sum by (datname) (pg_database_size_bytes{{{D}}})))', "{{datname}}"), instant=True),
                      "bytes", w=12, h=12))
    p.append(timeseries(g, "Replication lag", targets((f'max(pg_replication_lag_seconds{{{D}}})', "lag")),
                        "s", w=12, h=12, minv=0, fill=10,
                        desc="Only meaningful on a replica (pg_replication_is_replica = 1)."))
    return dashboard("amf-postgres", "PostgreSQL", p,
                     [ds_var(), query_var("database", "Database", "label_values(pg_up, database)")],
                     "postgres-exporter on db1/db2 (production and develop).", tags=("postgres",))


# ── 4. Monitoring health ──────────────────────────────────────────────────────────────────────
def monitoring():
    g = Grid()
    p = [
        table(g, "Firing alerts", targets(('ALERTS{alertstate="firing", alertname!="Watchdog"}', ""), instant=True, fmt="table"),
              h=7, desc="Everything currently firing (the Watchdog heartbeat is hidden). Alerts are emailed by Alertmanager on db1.",
              transformations=[{"id": "organize", "options": {
                  "excludeByName": {"Time": True, "Value": True, "__name__": True, "alertstate": True, "job": True,
                                    "instance": True, "fstype": True},
                  "indexByName": {"alertname": 0, "severity": 1, "host": 2, "mountpoint": 3, "device": 4},
                  "renameByName": {"alertname": "Alert", "severity": "Severity", "host": "Host",
                                   "mountpoint": "Mount", "device": "Device"}}}],
              overrides=[{"matcher": {"id": "byName", "options": "Severity"},
                          "properties": [{"id": "mappings", "value": [{"type": "value", "options": {
                              "critical": {"text": "● critical", "color": CRITICAL},
                              "warning": {"text": "● warning", "color": WARNING}}}]},
                                         {"id": "custom.cellOptions", "value": {"type": "color-text"}}]}]),
    ]
    p.append(row(g, "Prometheus (db1 & db2)"))
    p.append(timeseries(g, "Samples ingested per second",
                        targets(('sum by (host) (rate(prometheus_tsdb_head_samples_appended_total{job=~"prometheus-db.*"}[$__rate_interval]))', "{{host}}")),
                        "short", w=8, minv=0, fill=0, overrides=host_overrides(),
                        desc="db1 and db2 should track each other: every host pushes to both."))
    p.append(timeseries(g, "Active series", targets(('max by (host) (prometheus_tsdb_head_series{job=~"prometheus-db.*"})', "{{host}}")),
                        "short", w=8, minv=0, fill=0, overrides=host_overrides()))
    p.append(timeseries(g, "Storage used",
                        targets(('max by (host) (prometheus_tsdb_storage_blocks_bytes{job=~"prometheus-db.*"} + prometheus_tsdb_wal_storage_size_bytes{job=~"prometheus-db.*"} + prometheus_tsdb_head_chunks_storage_size_bytes{job=~"prometheus-db.*"})', "{{host}}")),
                        "bytes", w=8, minv=0, fill=0, overrides=host_overrides(),
                        desc="Capped by --storage.tsdb.retention.size (db1 100 GB, db2 300 GB) and 90 days."))
    p.append(timeseries(g, "Late samples accepted (back-fill after an outage)",
                        targets(('sum by (host) (rate(prometheus_tsdb_head_out_of_order_samples_appended_total{job=~"prometheus-db.*"}[$__rate_interval]))', "{{host}}")),
                        "short", w=12, minv=0, fill=10, overrides=host_overrides(),
                        desc="Non-zero right after a Prometheus outage: Alloy re-sending what it buffered."))
    p.append(timeseries(g, "Samples rejected (would leave a gap)",
                        targets(('sum by (host) (rate(prometheus_tsdb_out_of_bound_samples_total{job=~"prometheus-db.*"}[$__rate_interval]) + rate(prometheus_tsdb_too_old_samples_total{job=~"prometheus-db.*"}[$__rate_interval]))', "{{host}}")),
                        "short", w=12, minv=0, fill=10, overrides=host_overrides(),
                        thresh=thresholds((None, "transparent"), (0.001, CRITICAL)), thresh_style="dashed",
                        desc="Should always be 0. Anything else fires PrometheusRejectingSamples."))
    p.append(row(g, "Alertmanager (db1)"))
    p.append(timeseries(g, "Notifications sent / failed",
                        targets(('sum by (integration) (increase(alertmanager_notifications_total{job="alertmanager", integration=~"email|webhook"}[$__rate_interval]))', "sent · {{integration}}"),
                                ('sum by (integration) (increase(alertmanager_notifications_failed_total{job="alertmanager", integration=~"email|webhook"}[$__rate_interval]))', "failed · {{integration}}")),
                        "short", minv=0, fill=10,
                        desc="email = alerts to ALERT_EMAIL_TO; webhook = Watchdog heartbeat (once healthchecks.io is set up)."))
    p.append(stat(g, "Active silences", targets('max(alertmanager_silences{job="alertmanager", state="active"})'),
                  w=6, h=8, thresh=thresholds((None, GOOD), (1, WARNING)),
                  desc="Silenced alerts are NOT emailed. Should normally be 0."))
    p.append(stat(g, "Hosts sending to both Prometheus", targets('count(count by (host) (up{job="nodeexporter"}))'),
                  w=6, h=8, thresh=thresholds((None, CRITICAL), (6, GOOD)),
                  desc="Hosts with node-exporter data arriving through Alloy (expected: 6; prod4 later)."))
    return dashboard("amf-monitoring", "Monitoring health", p, [ds_var()],
                     "Is the monitoring itself healthy?", tags=("monitoring",))


# ── 5. Certificates ───────────────────────────────────────────────────────────────────────────
def certificates():
    g = Grid()
    C = 'job="certificates"'
    DAYS = f'(probe_ssl_earliest_cert_expiry{{{C}}} - time()) / 86400'
    DAYS_T = thresholds((None, CRITICAL), (7, WARNING), (30, GOOD))
    p = [
        stat(g, "Certificates checked", targets(f'count(probe_success{{{C}}})'), w=6, color_mode="none",
             desc="HTTPS names checked every minute by db1's Alloy (list: deploy/alloy/certificate-targets.txt)."),
        stat(g, "Valid now", targets(f'count(probe_success{{{C}}} == 1) or vector(0)'), w=6,
             thresh=thresholds((None, GOOD))),
        stat(g, "Check failing", targets(f'count(probe_success{{{C}}} == 0) or vector(0)'), w=6,
             thresh=thresholds((None, GOOD), (1, CRITICAL)),
             desc="Expired, not trusted by the Amfileon CA, issued for another name, or unreachable → CertificateCheckFailed."),
        stat(g, "Soonest expiry", targets(f'min({DAYS})'), "d", w=6, decimals=0, thresh=DAYS_T,
             desc="Days until the next certificate expires. Alerts: warning < 30 days, critical < 7 days."),
    ]
    p.append(table(
        g, "All certificates (soonest expiry first)",
        targets((DAYS, ""), (f'probe_ssl_earliest_cert_expiry{{{C}}} * 1000', ""), (f'probe_success{{{C}}}', ""),
                instant=True, fmt="table"),
        h=20,
        transformations=[
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {
                "excludeByName": {"Time": True, "job": True, "instance": True, "host": True, "__name__": True},
                "indexByName": {"certificate": 0, "Value #A": 1, "Value #B": 2, "Value #C": 3},
                "renameByName": {"certificate": "Certificate", "Value #A": "Days left",
                                 "Value #B": "Expires", "Value #C": "Check"}}},
        ],
        sort=[{"displayName": "Days left", "desc": False}],
        overrides=[
            {"matcher": {"id": "byName", "options": "Days left"},
             "properties": [{"id": "unit", "value": "none"}, {"id": "decimals", "value": 0},
                            {"id": "thresholds", "value": DAYS_T},
                            {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
            {"matcher": {"id": "byName", "options": "Expires"},
             "properties": [{"id": "unit", "value": "dateTimeAsLocalNoDateIfToday"}]},
            {"matcher": {"id": "byName", "options": "Check"},
             "properties": [{"id": "mappings", "value": [{"type": "value", "options": {
                 "1": {"text": "✓ valid", "color": GOOD}, "0": {"text": "✗ failing", "color": CRITICAL}}}]},
                            {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
        ]))
    return dashboard("amf-certificates", "Certificates", p, [ds_var()],
                     "TLS certificates of the *.amf HTTPS services, as clients see them.", time_from="now-24h",
                     tags=("certificates",))


# ── 6. Traffic ────────────────────────────────────────────────────────────────────────────────
def traffic():
    g = Grid()
    NGX = 'job="nginx"'
    # Host network cards: cAdvisor's root cgroup (id="/") reports the host's own interfaces on every
    # host. Physical interfaces only (ens*/eno*/enp*); Docker bridges (br-*) would double-count.
    PHYS = 'job="cadvisor", id="/", interface=~"ens.*|eno.*|enp.*"'
    nic = lambda m: f'sum by (host) (rate(container_network_{m}_bytes_total{{{PHYS}}}[$__rate_interval]))'
    # Container traffic: bridged containers only (eth0), host-network containers excluded (they'd
    # report the whole host's traffic).
    CT = 'job="cadvisor", name!="", interface="eth0"'
    HOSTNET = 'unless on (host, name) container_network_receive_bytes_total{job="cadvisor", name!="", interface=~"ens.*|eno.*|enp.*"}'
    p = [
        stat(g, "Web requests / s (all hosts)", targets(f'sum(rate(nginx_http_requests_total{{{NGX}}}[5m]))'),
             "reqps", w=6, color_mode="none", decimals=1,
             desc="All HTTPS/HTTP requests handled by nginx-proxy (the *.amf services) on hosts with the nginx exporter: db1, db2, cpu1, prod3."),
        stat(g, "Open web connections", targets(f'sum(nginx_connections_active{{{NGX}}})'), w=6, color_mode="none"),
        stat(g, "Network in (all hosts)", targets(f'sum({nic("receive")})'), "Bps", w=6, color_mode="none",
             desc="Physical network cards of all hosts together (cAdvisor host-level counters)."),
        stat(g, "Network out (all hosts)", targets(f'sum({nic("transmit")})'), "Bps", w=6, color_mode="none"),
    ]
    p.append(row(g, "Web traffic (nginx-proxy)"))
    p.append(timeseries(g, "Requests per second", targets((f'sum by (host) (rate(nginx_http_requests_total{{{NGX}}}[$__rate_interval]))', "{{host}}")),
                        "reqps", minv=0, fill=0, overrides=host_overrides(),
                        desc="Totals per host. The nginx exporter (stub_status) has no per-site or status-code breakdown."))
    p.append(timeseries(g, "Open connections", targets((f'sum by (host) (nginx_connections_active{{{NGX}}})', "{{host}}")),
                        "none", minv=0, fill=0, overrides=host_overrides()))
    p.append(row(g, "Host network cards"))
    p.append(timeseries(g, "Received", targets((nic("receive"), "{{host}}")), "Bps", minv=0, fill=0, overrides=host_overrides(),
                        desc="Physical interfaces (ens*) of each host, from cAdvisor's host-level counters."))
    p.append(timeseries(g, "Sent", targets((nic("transmit"), "{{host}}")), "Bps", minv=0, fill=0, overrides=host_overrides()))
    p.append(row(g, "Containers"))
    p.append(bargauge(g, "Top 15 containers by network traffic now (in + out)",
                      targets((f'sort_desc(topk(15, sum by (host, name) (rate(container_network_receive_bytes_total{{{CT}}}[5m]) + rate(container_network_transmit_bytes_total{{{CT}}}[5m])) {HOSTNET}))',
                               "{{host}} / {{name}}"), instant=True),
                      "Bps", w=24, h=12,
                      desc="Containers on Docker networks (eth0). Host-network containers are excluded — they would show the whole host's traffic."))
    return dashboard("amf-traffic", "Traffic", p, [ds_var()],
                     "Web requests through nginx-proxy, host network cards, and the busiest containers.", tags=("traffic",))


def explain_empty(d):
    """Panels that are empty for a known reason say so instead of a bare 'No data'."""
    def walk(ps):
        for p in ps:
            yield p
            yield from walk(p.get("panels", []))
    for p in walk(d["panels"]):
        exprs = " ".join(t["expr"] for t in p.get("targets", []))
        msg = None
        if any(k in exprs for k in ("host-alive", "ALERTS", "prometheus-db", "alertmanager")):
            # Checks, alert rules and the monitoring of Prometheus/Alertmanager exist only on db1
            # (db2 is a pure copy of what Alloy pushes). Always read these from db1, whatever the
            # drop-down says — so db2 never shows a misleading "0 alerts".
            db1 = {"type": "prometheus", "uid": "prom-db1"}
            p["datasource"] = db1
            for t in p.get("targets", []):
                t["datasource"] = db1
            if p.get("title") and not p["title"].endswith("(db1)"):
                p["title"] += " (db1)"
            p["description"] = (p.get("description", "") + " Always read from Prometheus-db1: only db1 runs these checks; db2 only stores a copy of the hosts' metrics.").strip()
            continue
        elif "DCGM_" in exprs:
            msg = "No GPU on this host (GPU data: gpu1)"
        elif "scaph_" in exprs:
            msg = "No power data for this host (db2, prod3)"
        if msg and "fieldConfig" in p:
            p["fieldConfig"]["defaults"]["noValue"] = msg
    return d


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for d in map(explain_empty, (fleet(), host(), postgres(), monitoring(), certificates(), traffic())):
        path = OUT / f"{d['uid']}.json"
        path.write_text(json.dumps(d, indent=2) + "\n")
        print(f"wrote {path.name}: {len(d['panels'])} panels")
