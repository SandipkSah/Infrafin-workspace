# db1 — Grafana for the Amfileon dashboards (`https://grafana.amf`)

Adds `/srv/docker/grafana-dashboards` on db1: one Grafana container with the two Prometheus
datasources and all dashboards from `grafana-local/`, served by nginx-proxy over TLS.

**Touches nothing that exists.** dockprom's Grafana (`grafana.db1.amf`) keeps running unchanged.
No port is published; the container is only on `proxy_network`.

Prerequisites (you):
- certificate `/srv/docker/proxy/grafana.amf.crt` + `.key` on db1 (Amfileon CA) — done 2026-10-28
- DNS `grafana.amf → 10.10.10.20`

## 1. Stage (from your Mac, no root)

```bash
cd ~/Desktop/infrafin/Amfileon/prometheus_alloy_monitoring/deploy
./stage.sh grafana-dashboards db1
```

Regenerates the dashboards, puts compose file, provisioning, dashboards, CA and `.env`
(datasource password + admin password from `secrets/`) into `~/grafana-dashboards-deploy/`.

## 2. Install (you, on db1 — asks for the sudo password once)

```bash
ssh -t db1 'bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf'
```

Copies the files to `/srv/docker/grafana-dashboards`, copies the `grafana.amf` certificate into
nginx-proxy's certificate volume (if not there yet), and starts the container. docker-gen then adds
the `grafana.amf` vhost to nginx-proxy by itself.

## 3. Log in

`https://grafana.amf` — user `admin`, password in `deploy/secrets/grafana-admin.env` on your Mac
(store it in Infisical). Create accounts for the team under *Administration → Users* (role
Viewer is enough); LDAP can be added later.

## Updating dashboards

Change `grafana-local/gen_dashboards.py`, then `./stage.sh grafana-dashboards db1` — while
`/srv/docker/grafana-dashboards` is still ssa-owned the files go straight in place and Grafana picks
them up within 10 s, no restart. After the final lockdown, stage + install as above.

Rollback: `cd /srv/docker/grafana-dashboards && sudo docker compose down` (the vhost disappears
with the container).

## Single sign-on with authentik (live since 2026-11-01)

Login page shows "Sign in with authentik"; the local `admin` login stays as fallback. Optional later:
`GF_AUTH_OAUTH_AUTO_LOGIN=true` skips the login page (break-glass: `/login?disableAutoLogin=true`).

**authentik (https://auth.amf), application `Grafana AMF`, slug `grafana-amf`** — not the existing
"Grafana" application and not the group `grafana`: those belong to dockprom's Grafana (LDAP login).
- Provider: OAuth2/OpenID, Confidential, grant types Authorization Code + Refresh token only,
  redirect URI `https://grafana.amf/login/generic_oauth` (strict, authorization), logout URI
  `https://grafana.amf/logout`, extra scope `authentik default OAuth Mapping: Application Entitlements`.
- **Who may log in** = application bindings: groups `Grafana Admins`, `Grafana Users`.
- **Role** = application entitlements (authentik's documented way for Grafana):
  `Grafana Admins` → Admin (bound to group `Grafana Admins`), `Grafana Viewers` → Viewer (bound to
  group `Grafana Users`). Names must match `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`.
- Access is managed only in authentik: Grafana re-applies the role at every login (strict — without
  one of the two entitlements the login is refused).

**Grafana**: `GF_AUTH_GENERIC_OAUTH_*` in `docker-compose.yaml`; client ID/secret in `.env`, written by
`fill-grafana-oauth.sh` (asks, never prints). Switch off: `bash ~/fill-grafana-oauth.sh --off`, then
`bash ~/install-grafana-dashboards.sh grafana-dashboards grafana.amf`.
Rotate the secret: authentik provider → Edit → new secret, then the same two commands.
