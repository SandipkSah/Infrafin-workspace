# db2 — Prometheus (second copy)

Adds `/srv/docker/prometheus` on db2: a Prometheus that only **receives** Alloy pushes.
No scraping, no alert rules. Reached as `https://db2.prometheus.amf` through the existing
nginx-proxy (TLS) with Prometheus basic auth.

**Touches nothing that exists.** New compose project, new volume, joins the existing
`proxy_network`. dockprom's own `prometheus` container on db2 keeps running unchanged.

Already in place (checked read-only on 2026-10-26):
- DNS: `db2.prometheus.amf → 10.10.10.21`
- Certificate: `/srv/docker/proxy/db2.prometheus.amf.{crt,key}`, signed by the Amfileon CA, valid to 2036
- `/srv/docker/prometheus` does not exist yet; 794 GB free on `/`

---

## 0. Once, on your Mac — generate the secrets

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
./gen-secrets.sh            # writes secrets/*.env (git-ignored); prints nothing secret
```
Save the passwords in `secrets/alloy.env` and `secrets/grafana.env` in Infisical / your password
manager. `secrets/prometheus.env` (bcrypt hashes only) becomes the `.env` of Prometheus on db2
**and** db1.

## 1. Copy the files to db2 (no root needed)

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
ssh db2 'mkdir -p ~/prometheus-deploy && chmod 700 ~/prometheus-deploy'
scp db2/prometheus/docker-compose.yaml db2/prometheus/prometheus.yml db2:~/prometheus-deploy/
scp secrets/prometheus.env db2:~/prometheus-deploy/.env
```

## 2. On db2 — install (root)

```bash
ssh -t db2
sudo mkdir -p /srv/docker/prometheus
sudo cp -a ~/prometheus-deploy/. /srv/docker/prometheus/
rm -r ~/prometheus-deploy
```
`cp -a` keeps `ssa` as owner for now, so configs can still be adjusted during the rollout. The
final step in [../README.md](../README.md) locks everything to `root:root` like the other services.
Prometheus builds its basic-auth `web.yml` from `.env` at start-up (inside the container, in a
tmpfs), so no secret file sits in `/srv/docker/prometheus` besides `.env` — the same convention
as the other services under `srv_version_control`.

### 2a. Make sure nginx-proxy has the certificate

nginx-proxy reads certificates from its `certs` volume, named `<VIRTUAL_HOST>.crt/.key`.
Check whether it is already there:
```bash
sudo docker exec nginx-proxy ls /etc/nginx/certs | grep prometheus
```
If `db2.prometheus.amf.crt` and `.key` are **not** listed, copy them in, the same way the
other `*.amf` certificates got there (the volume is mounted read-only in nginx-proxy, so copy
into the volume directly):
```bash
CERTS=$(sudo docker volume inspect -f '{{.Mountpoint}}' proxy_certs)
sudo cp /srv/docker/proxy/db2.prometheus.amf.crt /srv/docker/proxy/db2.prometheus.amf.key "$CERTS/"
```

### 2b. Start it

```bash
cd /srv/docker/prometheus
sudo docker compose config -q && sudo docker compose up -d
sudo docker compose ps          # prometheus-prometheus-1 should be "Up"
sudo docker compose logs --tail 20
```
nginx-proxy picks up the new `VIRTUAL_HOST` automatically (docker-gen) within ~30 s.

## 3. Verify (from your Mac, no root)

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
./verify-prometheus.sh db2
```
Expected: 8 passed — DNS, TLS trusted, 401 without/with wrong password, 200 for `grafana`,
remote-write receiver on, `out_of_order_time_window` active.

## Rollback

```bash
cd /srv/docker/prometheus && sudo docker compose down        # add -v to also delete the data volume
```
Nothing else on db2 depends on it until Alloy is deployed.

## Notes

- Retention is **90 days** (`--storage.tsdb.retention.time=90d`); change in `docker-compose.yaml` if wanted.
- No `LETSENCRYPT_HOST` on purpose: `.amf` names can't get public certificates; the internal CA
  certificate above is used instead.
- No container healthcheck: with basic auth enabled, even `/-/healthy` needs a password, and
  that shouldn't go into the compose file. `verify-prometheus.sh` covers it from outside;
  db1's `HostDown` monitoring will cover it once db1 is set up.
- nginx-proxy uses nginx's default 1 MB request limit. Alloy's remote-write batches are far
  smaller (≈ 2000 samples, snappy-compressed); if `413 Request Entity Too Large` ever shows up in
  Alloy's logs, add `client_max_body_size 16m;` to `/etc/nginx/vhost.d/db2.prometheus.amf`.
