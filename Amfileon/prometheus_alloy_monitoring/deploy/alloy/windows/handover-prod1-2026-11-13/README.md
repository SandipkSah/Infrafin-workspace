# Handover 2026-11-13: prod1 QuantOffice logs + TimeBase JVM heap (from ssa's colleague)

`HANDOVER-ssa.md` + `config.alloy` as received (moved here from `~/Desktop/infrafin/`, unchanged).

**Do not install them as described.** They were written as if prod1 had no Alloy yet. Since
2026-11-13, prod1 runs **our** Alloy (`../config.alloy`, installed by `../install-alloy-prod1.ps1`):
Windows metrics renamed to node-exporter names (Fleet/Host dashboards, HostDown/HostDiskAlmostFull),
System/Application event logs → Loki, and the HTTP server on the LAN IP for db1's host-alive check.
Replacing that config with this one would drop all of those (and the UI on 127.0.0.1 only would make
db1's host-alive check fail → HostDown prod1), and it uses another secrets folder.

**Installed on prod1 2026-11-13 ~16:15 CET, verified:** StrategyServer (4 files) and TimeBase (1 file)
logs arriving with levels; Ember: `ember-monitor` arriving (41k lines for the day), `ember-service` not yet —
no ember-service file changed in the 2 h window at start (picked up automatically when written again);
`windows_process_handles` TimeBaseSvcLauncher ≈ 260k; `timebase-jvm` up=0 until Saturday, no alert.
TODO after Saturday's TimeBase restart: check `up{job="timebase-jvm"}`, add the heap (>85 % 2 min) and
JVM-down alerts, then remove `timebase-jvm` from the ExporterDown exemption.

**Merged:** the new parts are in `../prod1.alloy`
(appended to `../config.alloy` for prod1 only by `gen_windows.py`) + the `process` collector in
`../config.alloy`; `timebase-jvm` is exempt from ExporterDown until it delivers. Tested: full prod1
config validates; sample lines → levels crit/err/warning/info, `service` label for Ember, stack traces
folded, timestamps from the line (UTC), secrets redacted.

**Original plan:** merge the *new* parts into `../config.alloy` and redeploy with the generated installer:
- `loki.source.file` for StrategyServer/OMS, Ember and TimeBase logs (multiline, timestamp, level,
  `service` label for Ember, same redaction), `ignore_older_than = "2h"` (no backfill)
- `prometheus.scrape "timebase_jvm"` → `127.0.0.1:9404` (JMX exporter; up=0 until TimeBase is
  restarted with the javaagent — their Saturday step)
- `process` collector (with the include filter) added to our existing `prometheus.exporter.windows`
- not taken over: their own `remote_write`/`loki.write` (ours exist), `job="windows"` for host metrics
  (would duplicate our node_* series), passwords written with `Set-Content` on the command line (they end
  up in PowerShell history — our installer reads them from env.txt and deletes it)

Validated 2026-11-13: their `config.alloy` passes `alloy validate` (v1.21.2), incl. `ignore_older_than`
and `process { include }`.

Their suggested alerts (after Saturday): TimeBase heap > 85 % for 2 min; TimeBaseSvcLauncher handle count
rising sharply (baseline ~258k; the 11-12 OOM came from ~220k file readers opened by ~30 dxapi queries).
