# GitLab Container Registry — Configuration Reference

Reference for configuring the bundled Container Registry in **Omnibus GitLab** (the all-in-one
`gitlab/gitlab-ce` Docker image). In Docker, all `gitlab.rb` settings below go inside the
`GITLAB_OMNIBUS_CONFIG: |` block of `docker-compose.yaml`; apply with a container recreate +
`gitlab-ctl reconfigure`.

> Amfileon context: registry served at `registry2.amf`, TLS terminated by the **external nginx-proxy**
> (so the bundled registry nginx runs plain HTTP behind it), metadata database enabled. The
> Amfileon-specific values are called out inline.

---

## 1. How the registry fits in

The Container Registry is an **OCI/Docker Distribution HTTP server** bundled in the Omnibus image and
supervised by `runit` alongside nginx, puma, PostgreSQL, etc. It stores image **blobs** on disk and
(in next-gen mode) its **metadata** in PostgreSQL. GitLab itself provides the **auth** (JWT tokens),
so the registry and GitLab must be the same instance / share config.

Three network layers to keep straight:
- `registry['registry_http_addr']` — where the **registry process** listens internally (default `localhost:5000`).
- `registry_nginx['listen_port']` — where the **bundled nginx** exposes the registry (proxies to the above).
- `registry_external_url` — the **public URL** clients use (`docker login <this>`).

---

## 2. Core enable / URL directives

| Directive | Purpose | Amfileon value |
|-----------|---------|----------------|
| `gitlab_rails['registry_enabled']` | Turns on GitLab's registry API integration | `true` |
| `registry['enable']` | Whether the registry **service** runs (defaults on when `registry_external_url` set) | (implicit) |
| `registry_external_url` | Public URL clients use for `docker login`/push/pull | `'https://registry2.amf'` |

```ruby
gitlab_rails['registry_enabled'] = true
registry_external_url 'https://registry2.amf'
```

**URL layout options:**
- **Separate domain** (Amfileon): `registry_external_url 'https://registry2.amf'` — needs its own TLS cert for that name.
- **Same domain, different port:** `registry_external_url 'https://gitlab.example.com:5050'` — registry shares the GitLab hostname on port 5050 (must differ from internal 5000). Clients then use `gitlab.example.com:5050`.

---

## 3. nginx directives (bundled registry nginx)

| Directive | Purpose |
|-----------|---------|
| `registry_nginx['listen_port']` | Port the bundled registry nginx listens on |
| `registry_nginx['listen_https']` | Whether that nginx terminates TLS itself |
| `registry_nginx['proxy_set_headers']` | Extra headers forwarded upstream |
| `registry_nginx['ssl_certificate']` / `['ssl_certificate_key']` | Cert paths **if** the bundled nginx terminates TLS |
| `registry_nginx['redirect_http_to_https']` | Force HTTP→HTTPS |

### Case A — TLS terminated by an EXTERNAL reverse proxy (Amfileon)

The external nginx-proxy holds the cert (`registry2.amf.crt`) and terminates HTTPS; the bundled
registry nginx runs plain HTTP and just needs to know the real scheme is HTTPS:

```ruby
registry_nginx['listen_port'] = 80
registry_nginx['listen_https'] = false
registry_nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl"   => "on"
}
```
> `registry_external_url 'https://…'` already tells the registry its external scheme is HTTPS, so it
> advertises correct `https://` blob URLs even though the internal hop is HTTP. The external proxy must
> route the `registry2.amf` vhost to this container's `listen_port` (via `VIRTUAL_HOST`).

### Case B — bundled nginx terminates TLS itself (no external proxy)

```ruby
registry_nginx['ssl_certificate']     = "/etc/gitlab/ssl/registry2.amf.crt"
registry_nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/registry2.amf.key"
registry_nginx['redirect_http_to_https'] = true
```

---

## 4. Metadata database (next-generation registry)

Moves registry metadata from the filesystem into PostgreSQL → enables **online garbage collection**,
storage stats, protected tags, faster tag listing. Required for all new registry features.

```ruby
registry['database'] = { 'enabled' => true }
```
- **New install (Amfileon):** enable from first boot → no legacy metadata ever, no risky import.
  On GitLab 18.3+/19.x the DB is auto-provisioned on the bundled PostgreSQL.
- **Existing legacy registry:** requires a one-time metadata **import** (one-step or three-step) — see
  the migration runbook, not needed here.
- Verify it's active (header returned even on the 401):
  ```bash
  curl -sI https://registry2.amf/v2/ | grep -i gitlab-container-registry-database-enabled   # true
  ```
- External/dedicated DB variant:
  ```ruby
  registry['database'] = {
    'enabled'  => true,
    'host'     => 'db-host', 'port' => 5432,
    'user'     => 'registry', 'password' => '<pw>', 'dbname' => 'registry',
    'sslmode'  => 'require'
  }
  ```

---

## 5. Storage

| Directive | Purpose | Default |
|-----------|---------|---------|
| `gitlab_rails['registry_path']` | Local filesystem path for image blobs | `/var/opt/gitlab/gitlab-rails/shared/registry` |
| `registry['storage']` | Storage backend (filesystem / S3 / Azure / GCS) | filesystem |

The metadata DB does **not** replace blob storage — you always keep a filesystem or object-storage
backend. Object-storage (S3-compatible) example:
```ruby
registry['storage'] = {
  's3' => { 'accesskey' => '<key>', 'secretkey' => '<secret>',
            'bucket' => '<bucket>', 'region' => '<region>' }
}
```
> Amfileon has MinIO / rustfs (S3-compatible) available — an object-storage backend is an option
> instead of local disk, but not required for the current task.

---

## 6. Internal listen address & default project feature

```ruby
registry['registry_http_addr'] = "localhost:5000"   # internal registry process addr (default)
gitlab_rails['gitlab_default_projects_features_container_registry'] = true   # new projects get registry
```

---

## 7. Applying changes

**Docker (Amfileon):**
```bash
cd /srv/docker/gitlab-registry-2
docker compose up -d                            # recreate — required when env/GITLAB_OMNIBUS_CONFIG changed
docker exec gitlab-ce2 gitlab-ctl reconfigure   # applies gitlab.rb
docker exec gitlab-ce2 gitlab-ctl status | grep registry   # run: registry:
```
- Env/`VIRTUAL_HOST`/`GITLAB_OMNIBUS_CONFIG` changes → need `up -d` (recreate).
- `reconfigure` alone only re-reads an already-mounted `gitlab.rb`.

**Non-Docker Omnibus:** edit `/etc/gitlab/gitlab.rb` → `sudo gitlab-ctl reconfigure`.

---

## 8. Verifying

```bash
# process up
docker exec gitlab-ce2 gitlab-ctl status | grep registry        # run: registry:

# API alive (401 = healthy, needs auth)
curl -sI https://registry2.amf/v2/                              # HTTP 401

# next-gen metadata DB active
curl -sI https://registry2.amf/v2/ | grep -i gitlab-container-registry-database-enabled   # true

# end-to-end auth
docker login registry2.amf                                      # Login Succeeded
```

---

## 9. Authenticating (docker login)

GitLab issues the registry's auth. Credentials options:
- **Username + password** of a GitLab user (LDAP users work; Amfileon uses LDAP).
- **Personal Access Token** with scopes `read_registry` / `write_registry` (recommended — don't store
  your real password in Docker). Username = your username, password = the token.
- **Deploy token** (per-project, for CI/automation).
- **CI job token** (`$CI_JOB_TOKEN`) inside pipelines, automatically.

To `docker push`, the target **project/namespace must exist**: images live at
`registry2.amf/<group>/<project>[/<image>]`.

---

## 10. Full minimal Amfileon block (reference)

```ruby
# Registry
gitlab_rails['registry_enabled'] = true
registry_external_url 'https://registry2.amf'
registry_nginx['listen_port'] = 80
registry_nginx['listen_https'] = false
registry_nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "https",
  "X-Forwarded-Ssl"   => "on"
}
registry['database'] = { 'enabled' => true }
```

---

## Sources

- [GitLab container registry administration](https://docs.gitlab.com/administration/packages/container_registry/)
- [Container registry metadata database](https://docs.gitlab.com/administration/packages/container_registry_metadata_database/)
- [Container registry metadata database for new installations](https://docs.gitlab.com/administration/packages/container_registry_metadata_database_new_install/)
- [Authenticate with the container registry](https://docs.gitlab.com/user/packages/container_registry/authenticate_with_container_registry/)
