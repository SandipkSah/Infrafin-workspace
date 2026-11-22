# prod1 (10.10.10.11, Windows) — Alloy for logs + TimeBase heap

**Goal:** get prod1's QuantOffice logs into Loki, and the TimeBase JVM heap and host metrics into Prometheus, using a local Alloy on prod1. db2's Alloy is not touched. The attached `config.alloy` uses the same endpoints, users, CA and redaction rules as `common.alloy` and `logs.alloy`.

**When:** after the US close, from about 21:15 UTC. Installing needs no restart of TimeBase, StrategyServer or Ember.

## What it collects
| What | Path on prod1 | Labels |
|---|---|---|
| StrategyServer / OMS logs (~10 MB/day) | `Q:\QSHome56\QuantOffice56\StrategyServerHome\logs\*.log` | `job=strategyserver` |
| Ember logs incl. `ember-service.out.log` (~30 MB/day) | `Q:\QSHome56\QuantOffice56\EmberHome\service\logs\**\*.log` | `job=ember`, `service=ember-service` / `ember-monitor` / … |
| TimeBase logs (~150 MB/day) | `Q:\QSHome56\QuantOffice56\TimebaseHome\logs\deltix_TimeBase-*.log` | `job=timebase` |
| TimeBase JVM heap / GC | JMX exporter on `127.0.0.1:9404`, live after Saturday's TB restart (`up=0` until then) | `job=timebase-jvm` |
| Windows host + QuantOffice process memory/handles | built-in `prometheus.exporter.windows` | `job=windows` |

- All series and streams also carry `host=prod1` and `level`.
- On first start it reads only files modified in the last 2 h (`ignore_older_than`), so there is no backfill of the 3.6 GB StrategyServer history.
- All three log formats start with `YYYY-MM-DD HH:MM:SS.fff` in UTC; continuation lines (stack traces) are folded into the line before them.

## Steps (on prod1, as Administrator)
1. Get the installer, **Alloy v1.21.2**, the same version as db2:
   `https://github.com/grafana/alloy/releases/download/v1.21.2/alloy-installer-windows-amd64.exe`
   sha256 `2fea06c9e597acab6f79470b1fb247165d13d6faf17b645c967526619974bdc6`
2. Install it silently:
   `alloy-installer-windows-amd64.exe /S /DISABLEREPORTING=yes`
   This creates the service `Alloy` with its config at `C:\Program Files\GrafanaLabs\Alloy\config.alloy`, and the UI on `127.0.0.1:12345` only.
3. Create the secrets folder and lock it down:
   ```powershell
   $d='C:\ProgramData\GrafanaLabs\Alloy\amf'; New-Item -ItemType Directory -Force $d | Out-Null
   Copy-Item <amfileon-ca.pem from /srv/docker/alloy/ on db2> "$d\amfileon-ca.pem"
   Set-Content -NoNewline "$d\loki_password" '<LOKI_PASSWORD>'     # user "alloy"
   Set-Content -NoNewline "$d\prom_password" '<ALLOY_PASSWORD>'    # user "alloyuser"
   icacls $d /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
   ```
4. Put the attached `config.alloy` in place and restart the service:
   ```powershell
   Copy-Item .\config.alloy 'C:\Program Files\GrafanaLabs\Alloy\config.alloy' -Force
   Restart-Service Alloy; Get-Service Alloy
   ```
5. Check it's working:
   - Open `http://127.0.0.1:12345` on prod1. All components should be healthy, apart from the `timebase_jvm` scrape, which stays down until Saturday.
   - In Grafana: `{host="prod1", job="ember", service="ember-service"}`, `{host="prod1", job="strategyserver"}`, `up{host="prod1"}`.

## Config details I couldn't test, so please check them
- I couldn't run Alloy here, so the config has not been validated.
- Two settings are written from the docs and not tested:
  - `ignore_older_than` in `local.file_match`;
  - the `process { include = … }` block in `prometheus.exporter.windows`.
- If either fails, it shows in the Alloy UI or the Windows Event Log (source `Alloy`).
- Feel free to move this into `deploy/alloy/hosts/prod1` in your repo.

## Saturday (TimeBase restart window), for whoever does the restart
- Already staged on prod1:
  - `C:\jmx\jmx_prometheus_javaagent-1.0.1.jar` and `C:\jmx\config.yaml`;
  - `Q:\QSHome56\QuantOffice56\TimebaseHome\services\config.txt.jmx`, which is the live `config.txt` plus one line, with the same LF line endings:
    `-javaagent:C:\jmx\jmx_prometheus_javaagent-1.0.1.jar=127.0.0.1:9404:C:\jmx\config.yaml`
  - Backup of the live config: `config.txt.bak-20261113`.
- Apply: stop `QuantOffice56_Timebase`, copy `config.txt.jmx` over `config.txt`, then start it again.
  Check with `curl http://127.0.0.1:9404/metrics` on prod1; `jvm_memory_max_bytes{area="heap"}` should be about 8.59e9.
- Rollback: copy `config.txt.bak-20261113` back over `config.txt` and restart.
- Suggested alerts:
  - `jvm_memory_used_bytes{area="heap",host="prod1"} / jvm_memory_max_bytes{area="heap",host="prod1"} > 0.85` for 2 min;
  - process handle count for TimeBaseSvcLauncher rising sharply. The baseline is about 258k; the OOM on 11-12 came from a burst of about 30 dxapi queries opening about 220k file readers.
