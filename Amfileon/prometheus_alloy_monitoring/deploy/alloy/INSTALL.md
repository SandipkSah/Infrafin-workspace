# Alloy — on every host (db1, db2, cpu1, cpu2, gpu1, prod3)

Adds `/srv/docker/alloy`: one container that scrapes the exporters dockprom already runs on that
host (by name, on dockprom's `monitor-net` network) and pushes everything to **both**
`db1.prometheus.amf` and `db2.prometheus.amf`.

**Touches nothing that exists.** No apt packages, no change to dockprom. Publishes Alloy's
default HTTP port **12345** on the host's LAN IP so db1 can check the host is alive.

**Order:** db2 Prometheus → db1 Prometheus → Alloy on one host (start with cpu2: fewest
exporters) → check → remaining hosts one by one.

What each host scrapes (common: `nodeexporter`, `cadvisor`, `pushgateway`):

| Host | Extra jobs |
|---|---|
| db1 | nginx, postgres-db1, postgres-db1-develop |
| db2 | nginx, scaphandre, postgres-db2, postgres-db2-develop |
| cpu1 | nginx |
| cpu2 | scaphandre |
| gpu1 | scaphandre, nvidia_dcg_export |
| prod3 | nginx, scaphandre |

---

## 1. Stage (from your Mac, no root) — per host

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
./stage.sh alloy cpu2
```
The staged `.env` contains `ALLOY_PASSWORD` (secret), `AMF_HOST`, `AMF_HOST_IP`.

## 2. On the host — install (root)

```bash
ssh -t cpu2
sudo docker network ls | grep monitor-net      # must show dockprom_monitor-net
sudo mkdir -p /srv/docker/alloy
sudo cp -a ~/alloy-deploy/. /srv/docker/alloy/
rm -r ~/alloy-deploy
cd /srv/docker/alloy
sudo docker compose config -q && sudo docker compose up -d
sudo docker compose logs --tail 30             # look for "Alloy is running", no remote_write errors
```

## 3. Verify (from your Mac, no root)

```bash
./verify-host.sh cpu2
```
Checks: Alloy reachable on :12345 from your machine, and fresh data from this host on **both**
Prometheus instances for every job listed above.

## Rollback

```bash
cd /srv/docker/alloy && sudo docker compose down          # -v also deletes the WAL volume
```

## Notes

- `HostDown` for this host clears within ~2 minutes of Alloy starting.
- If the logs show `x509: certificate signed by unknown authority`, the staged
  `amfileon-ca.pem` doesn't match the CA nginx-proxy's certificate was signed with.
- If they show `no such host` for `*.prometheus.amf`, the container can't use the host's DNS;
  add `extra_hosts: ["db1.prometheus.amf:10.10.10.20", "db2.prometheus.amf:10.10.10.21"]`
  to `docker-compose.yaml`.
