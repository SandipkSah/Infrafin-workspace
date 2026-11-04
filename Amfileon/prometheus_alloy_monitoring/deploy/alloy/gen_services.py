#!/usr/bin/env python3
"""Writes, per host listed in alloy/service-targets.txt:

  hosts/<host>.services.alloy   ClickHouse / Redis / GitLab collection (only the lines marked "on")
  hosts/<host>.compose.yaml     Docker networks Alloy joins (stage.sh → docker-compose.override.yaml)
  hosts/<host>.redis-list       every Redis container on the host, for deploy/services/fill-redis-env.sh

ClickHouse and GitLab are scraped over their Docker network (their metrics ports are not
published on the LAN). Redis is read by Alloy's built-in exporter on the already published port;
its password comes from REDIS_PASSWORD_<NAME> in /srv/docker/alloy/redis.env. TLS-only instances
(rediss://<cert name>:<port>) are reached by the name on their certificate, which the Alloy
container resolves to its own host (extra_hosts), so the certificate is fully verified.
"""
import pathlib
import re
import sys

HOST_IP = {"db1": "10.10.10.20", "db2": "10.10.10.21", "cpu1": "10.10.10.30",
           "cpu2": "10.10.10.31", "gpu1": "10.10.10.40", "prod3": "10.10.10.13", "prod4": "10.10.10.14"}

import argparse

here = pathlib.Path(__file__).parent
ap = argparse.ArgumentParser()
ap.add_argument("--targets", default=str(here / "service-targets.txt"))
ap.add_argument("--out", default=str(here / "hosts"), help="output folder (default: alloy/hosts)")
args = ap.parse_args()
out_dir = pathlib.Path(args.out)
rows = []
for n, line in enumerate(pathlib.Path(args.targets).read_text().splitlines(), 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    f = line.split()
    if len(f) != 8 or f[1] not in ("clickhouse", "redis", "gitlab") or f[7] not in ("on", "off"):
        sys.exit(f"service-targets.txt:{n}: expected 8 columns (host kind name cluster role address network on|off)")
    rows.append(dict(zip(("host", "kind", "name", "cluster", "role", "address", "network", "on"), f), line=n))

bad = [r for r in rows if r["on"] == "on" and r["kind"] != "redis" and r["network"] in ("?", "host?", "-")]
if bad:
    sys.exit("these are switched on but have no Docker network yet: "
             + ", ".join(f"line {r['line']} {r['name']}" for r in bad))


def ident(s):
    return re.sub(r"[^A-Za-z0-9_]", "_", s)


def env_var(name):
    return "REDIS_PASSWORD_" + ident(name).upper()


def clickhouse(rs):
    tg = "\n".join(f'    {{ "__address__" = "{r["address"]}", "clickhouse" = "{r["name"]}", '
                   f'"cluster" = "{r["cluster"]}", "role" = "{r["role"]}" }},' for r in rs)
    return f'''
// ── ClickHouse: built-in Prometheus endpoint (:9363) of each server and keeper ─────────────────
prometheus.scrape "clickhouse" {{
  job_name        = "clickhouse"
  targets         = [
{tg}
  ]
  scrape_interval = "30s"
  forward_to      = [prometheus.relabel.clickhouse.receiver]
}}

// per-CPU / per-disk / per-NIC copies of host metrics (node-exporter already has them) and the
// latency histograms — not used by any dashboard or alert
prometheus.relabel "clickhouse" {{
  forward_to = [prometheus.remote_write.both.receiver]

  rule {{
    source_labels = ["__name__"]
    regex         = "ClickHouseHistogramMetrics_.*|ClickHouseAsyncMetrics_(OS[A-Za-z]+CPU[0-9]+|CPUFrequencyMHz_[0-9]+|Block[A-Za-z]+_.+|Network(Receive|Send)[A-Za-z]+_.+|Temperature.*)"
    action        = "drop"
  }}
}}
'''


def redis(rs):
    out = ["\n// ── Redis: Alloy's built-in redis exporter, one per instance ─────────────────────────────────────"]
    for r in rs:
        c = ident(r["name"])
        addr = r["address"].rsplit("/", 1)[0]
        tls = '\n  tls_ca_cert_file = "/etc/alloy-ca/amfileon-ca.pem"' if addr.startswith("rediss://") else ""
        pad = "  " if tls else ""   # alloy fmt alignment
        out.append(f'''
prometheus.exporter.redis "{c}" {{
  redis_addr     {pad}= "{addr}"
  redis_password {pad}= sys.env("{env_var(r["name"])}")   // from redis.env; empty = no password{tls}
}}

discovery.relabel "{c}" {{
  targets = prometheus.exporter.redis.{c}.targets
  rule {{
    target_label = "redis"
    replacement  = "{r["name"]}"
  }}
  rule {{
    target_label = "cluster"
    replacement  = "{r["cluster"]}"
  }}
  rule {{
    target_label = "kind"     // server|sentinel ("role" is the exporter's master/slave label)
    replacement  = "{r["role"]}"
  }}
  rule {{
    target_label = "job"
    replacement  = "redis"
  }}
}}''')
    outputs = ", ".join(f"discovery.relabel.{ident(r['name'])}.output" for r in rs)
    out.append(f'''
prometheus.scrape "redis" {{
  targets         = array.concat({outputs})
  scrape_interval = "30s"
  // the exporters are served by Alloy's own HTTP server, which requires the login (http.alloy)
  basic_auth {{
    username = "admin"
    password = sys.env("ALLOY_HTTP_PASSWORD")
  }}
  forward_to = [prometheus.remote_write.both.receiver]
}}
''')
    return "\n".join(out)


GITLAB_PATH = {"exporter": "/sidekiq"}   # gitlab-exporter: Sidekiq queue sizes and latency


def gitlab(rs):
    tg = "\n".join(
        f'    {{ "__address__" = "{r["address"]}", "__metrics_path__" = "{GITLAB_PATH.get(r["role"], "/metrics")}", '
        f'"job" = "gitlab-{r["role"]}", "gitlab" = "{r["name"]}" }},' for r in rs)
    return f'''
// ── GitLab: Puma, Workhorse, Sidekiq and gitlab-exporter metrics ports inside the container ────
prometheus.scrape "gitlab" {{
  targets         = [
{tg}
  ]
  scrape_interval = "30s"
  forward_to      = [prometheus.relabel.gitlab.receiver]
}}

// Drops ~80 % of GitLab's series that no dashboard uses (measured in services-rehearsal/:
// 16 300 → ~3 000): the SLI counters GitLab pre-creates for every endpoint and GraphQL query
// (gitlab_sli_*), per-worker Sidekiq concurrency limits, histograms and _sum, Rails/SQL latency histograms and the
// Workhorse size histograms. Kept: request counts/latency (Workhorse), Puma, Sidekiq job counts.
prometheus.relabel "gitlab" {{
  forward_to = [prometheus.remote_write.both.receiver]

  rule {{
    source_labels = ["__name__"]
    regex         = "gitlab_sli_.*|gitlab_ruby_threads_.*|sidekiq_concurrency_limit_.*|loose_foreign_key_.*|sidekiq_.*_bucket|sidekiq_jobs_completion_seconds_sum|(gitlab_sql|gitlab_sql_primary|gitlab_transaction|gitlab_redis_client_requests|http_request)_duration_seconds_bucket|gitlab_workhorse_http_(request|response)_size_bytes_bucket|gitlab_workhorse_http_time_to_write_header_seconds_bucket"
    action        = "drop"
  }}
}}
'''


for host in sorted({r["host"] for r in rows}):
    mine = [r for r in rows if r["host"] == host]
    on = [r for r in mine if r["on"] == "on"]
    parts = [f"// GENERATED by alloy/gen_services.py from service-targets.txt — edit that file instead.\n"
             f"// {host}: {len(on)} of {len(mine)} listed ClickHouse/Redis/GitLab targets switched on."]
    for kind, fn in (("clickhouse", clickhouse), ("redis", redis), ("gitlab", gitlab)):
        rs = [r for r in on if r["kind"] == kind]
        if rs:
            parts.append(fn(rs))
    (out_dir / f"{host}.services.alloy").write_text("\n".join(parts).rstrip() + "\n")

    nets = sorted({r["network"] for r in on if r["network"] not in ("-", "?", "host?")})
    hosts_map = {m.group(1): HOST_IP[host] for r in on if r["kind"] == "redis"
                 for m in [re.match(r"rediss://([^:]+):", r["address"])] if m}
    names = sorted(hosts_map)
    compose = [f"# GENERATED by alloy/gen_services.py — copied to /srv/docker/alloy/docker-compose.override.yaml.",
               f"# Docker networks Alloy joins on {host} to reach ClickHouse/GitLab metrics ports (not published),",
               f"# and the Redis TLS names that must resolve to this host so their certificates verify.",
               "services:"]
    if nets or names:
        compose += ["  alloy:"]
        if nets:
            compose += ["    networks:", "      - monitor"] + [f"      - svc{i}" for i in range(len(nets))]
        if names:
            compose += ["    extra_hosts:"] + [f'      - "{n}:{hosts_map[n]}"' for n in names]
        if nets:
            compose += ["", "networks:"]
            for i, n in enumerate(nets):
                compose += [f"  svc{i}:", f"    name: {n}", "    external: true"]
    else:
        compose += ["  alloy: {}"]
    (out_dir / f"{host}.compose.yaml").write_text("\n".join(compose) + "\n")

    redis_rows = [r for r in mine if r["kind"] == "redis"]
    (out_dir / f"{host}.redis-list").write_text(
        "# GENERATED by alloy/gen_services.py — <container> <port inside the container> <env var>\n"
        + "".join(f"{r['name']} {r['address'].rsplit('/', 1)[1]} {env_var(r['name'])}\n" for r in redis_rows))

    print(f"{host}: {len(on)}/{len(mine)} on, networks: {', '.join(nets) or '-'}, redis listed: {len(redis_rows)}")
