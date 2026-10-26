# db1 — Prometheus (first copy) + alerting

Adds `/srv/docker/prometheus` on db1 with two containers:

- **prometheus** — receives Alloy pushes, checks every host's Alloy (`host-alive`), evaluates
  `alert.rules`. Reached as `https://db1.prometheus.amf` (nginx-proxy TLS + basic auth).
- **alertmanager** — emails alerts to `ALERT_EMAIL_TO` (for now `ssa@infrafin.de`, later the
  team address) and sends the `Watchdog` heartbeat to healthchecks.io every minute. Not exposed
  outside the project.

**Touches nothing that exists.** dockprom (its Prometheus, Grafana, Alertmanager) keeps running.

Already in place (checked read-only on 2026-10-26): DNS `db1.prometheus.amf → 10.10.10.20`,
certificate `/srv/docker/proxy/db1.prometheus.amf.{crt,key}`, `/srv/docker/prometheus` doesn't exist.

**Do db2 first** (db1 scrapes db2's Prometheus for the `PrometheusDown` alert).

---

## 0. Prepare (once)

- In **healthchecks.io**: create a check "Amfileon alerting (Watchdog)", period **1 minute**,
  grace **5 minutes**, with a notification to you / the team. Copy its ping URL.
- Mail goes out through the account Watchtower already uses (`amfileon@infrafin.net` via
  `mail.your-server.de:587`); you need its password, which is in `/srv/docker/watchtower/.env`.

## 1. Stage the files on db1 (from your Mac, no root)

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
./stage.sh prometheus db1
```

## 2. On db1 — install (root)

```bash
ssh -t db1
sudo mkdir -p /srv/docker/prometheus
sudo cp -a ~/prometheus-deploy/. /srv/docker/prometheus/
rm -r ~/prometheus-deploy
```

Fill in the two empty values in `.env` — everything else (recipient, SMTP server, sender) is
already set:
```bash
sudo nano /srv/docker/prometheus/.env
#   SMTP_PASSWORD=<Watchtower's mail password, from /srv/docker/watchtower/.env>
#   HEALTHCHECKS_PING_URL=<ping URL from step 0>
```
To change the recipient later (team address): edit `ALERT_EMAIL_TO` and run
`sudo docker compose up -d alertmanager`.

### 2a. Certificate in nginx-proxy

```bash
sudo docker exec nginx-proxy ls /etc/nginx/certs | grep prometheus
# if db1.prometheus.amf.crt/.key are missing:
CERTS=$(sudo docker volume inspect -f '{{.Mountpoint}}' proxy_certs)
sudo cp /srv/docker/proxy/db1.prometheus.amf.crt /srv/docker/proxy/db1.prometheus.amf.key "$CERTS/"
```

### 2b. Start

```bash
cd /srv/docker/prometheus
sudo docker compose config -q && sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs --tail 30
```

## 3. Verify (from your Mac, no root)

```bash
./verify-prometheus.sh db1
```

**Test email** (on db1) — fires a fake alert straight into Alertmanager; an email
"[FIRING:1] AlertmanagerTestEmail" should reach `ALERT_EMAIL_TO` within ~1 minute:
```bash
cd /srv/docker/prometheus
sudo docker compose exec alertmanager amtool alert add AlertmanagerTestEmail host=db1 \
  --annotation=summary="Test email from the new Alertmanager on db1" \
  --end="$(date -u -d '+5 min' +%Y-%m-%dT%H:%M:%SZ)" --alertmanager.url=http://localhost:9093
sudo docker compose logs --tail 20 alertmanager   # SMTP errors (auth, TLS) would show here
```
Then within ~2 minutes healthchecks.io should show the Watchdog check as **up**.

Until Alloy is deployed on a host, that host shows `HostDown` (nothing answers on :12345):
expect `HostDown` alerts for all hosts in the team channel **after 2 minutes**. To avoid that noise,
deploy Alloy on all hosts right after this step, or create a silence first:
```bash
sudo docker compose exec alertmanager amtool silence add alertname=HostDown \
  --duration=2h --comment="rolling out Alloy" --alertmanager.url=http://localhost:9093
```

## Rollback

```bash
cd /srv/docker/prometheus && sudo docker compose down   # -v also deletes the data volumes
```
Stopping it stops the Watchdog pings → healthchecks.io will page after the grace period;
pause that check first if the rollback is intentional.
