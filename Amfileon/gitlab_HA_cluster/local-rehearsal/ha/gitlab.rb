# Shared GitLab config for both "servers" (loaded via GITLAB_OMNIBUS_CONFIG).
# Mirrors the db1 production compose, minus TLS/LDAP/SMTP/Pages, plus the HA changes.

external_url 'http://gitlab.local-test.amf'
gitlab_rails['initial_root_password'] = ENV['GITLAB_ROOT_PASSWORD']
gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.77.0.0/24', '10.78.0.0/24']

# Secrets: identical on both nodes (from .env, like production)
gitlab_rails['db_key_base']     = ENV['DB_KEY_BASE']
gitlab_rails['secret_key_base'] = ENV['SECRET_KEY_BASE']
gitlab_rails['otp_key_base']    = ENV['OTP_KEY_BASE']

# HA change 1: external Postgres (stand-in for the Patroni VIP 10.10.10.18:15432)
postgresql['enable'] = false
gitlab_rails['db_adapter']  = 'postgresql'
gitlab_rails['db_encoding'] = 'unicode'
gitlab_rails['db_host']     = ENV['PG_HOST']
gitlab_rails['db_port']     = 5432
gitlab_rails['db_database'] = 'gitlabhq_production'
gitlab_rails['db_username'] = 'gitlab'
gitlab_rails['db_password'] = ENV['GITLAB_DB_PASSWORD']

# Registry with metadata DB on the same external Postgres
gitlab_rails['registry_enabled'] = true
registry_external_url 'http://registry.local-test.amf'
registry['database'] = {
  'enabled'  => true,
  'host'     => ENV['PG_HOST'],
  'port'     => 5432,
  'dbname'   => 'registry',
  'user'     => 'registry',
  'password' => ENV['REGISTRY_DB_PASSWORD'],
  'sslmode'  => 'disable',
}

# HA change 2: global server hooks dir (post-receive queues the pushed repo for immediate sync)
gitaly['configuration'] = {
  hooks: { custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks' },
}

# Keep the laptop happy
puma['worker_processes'] = 2
sidekiq['concurrency'] = 5
prometheus_monitoring['enable'] = false
gitlab_kas['enable'] = false
