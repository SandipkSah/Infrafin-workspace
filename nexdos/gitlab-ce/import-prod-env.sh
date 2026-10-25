#!/usr/bin/env bash
# Fills gitlab-ce's .env with the live values from the running production `gitlab` container
# (LDAP + SMTP settings incl. passwords, timezone, GitLab version). Reads `docker inspect`
# rather than prod's compose file, so it gets exactly what's live. Never prints values.
# Also appends any setting .env.example has but .env lacks (with the example's default),
# so an older .env keeps working when new settings are added. Only reads from production.
#
# Usage (as root, from anywhere): /srv/docker/gitlab-ce/import-prod-env.sh

set -euo pipefail

cd "$(dirname "$0")"
PROD="${PROD_GITLAB_CONTAINER:-gitlab}"
SUDO=""; [[ $EUID -eq 0 ]] || SUDO=sudo

# Prod's image tag can be `latest`, so read the real version off the running GitLab source.
version="$($SUDO docker exec "$PROD" cat /home/git/gitlab/VERSION | tr -d '[:space:]')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected prod VERSION: '$version'" >&2; exit 1; }
echo "prod GitLab version: $version" >&2

added=0
while IFS= read -r line; do
  key="${line%%=*}"
  grep -q "^$key=" .env || { printf '%s\n' "$line" >> .env; echo "added missing $key" >&2; added=$((added + 1)); }
done < <(grep -E '^[A-Z_]+=' .env.example)
echo "$added setting(s) added from .env.example" >&2

$SUDO docker inspect "$PROD" --format '{{range .Config.Env}}{{println .}}{{end}}' |
awk -v ver="$version-ce.0" '
  BEGIN {
    map["LDAP_LABEL"]="LDAP_LABEL";             map["LDAP_HOST"]="LDAP_HOST"
    map["LDAP_PORT"]="LDAP_PORT";               map["LDAP_METHOD"]="LDAP_ENCRYPTION"
    map["LDAP_VERIFY_SSL"]="LDAP_VERIFY_CERTIFICATES"
    map["LDAP_UID"]="LDAP_UID";                 map["LDAP_BIND_DN"]="LDAP_BIND_DN"
    map["LDAP_PASS"]="LDAP_BIND_PASSWORD";      map["LDAP_BASE"]="LDAP_BASE"
    map["LDAP_USER_FILTER"]="LDAP_USER_FILTER"
    map["LDAP_USER_ATTRIBUTE_USERNAME"]="LDAP_ATTRIBUTE_USERNAME"
    map["LDAP_USER_ATTRIBUTE_MAIL"]="LDAP_ATTRIBUTE_MAIL"
    map["GITLAB_TIMEZONE"]="GITLAB_TIME_ZONE"
    map["SMTP_HOST"]="SMTP_ADDRESS";            map["SMTP_PORT"]="SMTP_PORT"
    map["SMTP_USER"]="SMTP_USER_NAME";          map["SMTP_PASS"]="SMTP_PASSWORD"
    map["SMTP_DOMAIN"]="SMTP_DOMAIN";           map["SMTP_AUTHENTICATION"]="SMTP_AUTHENTICATION"
    map["SMTP_STARTTLS"]="SMTP_ENABLE_STARTTLS_AUTO"
    map["GITLAB_EMAIL"]="GITLAB_EMAIL_FROM";    map["GITLAB_EMAIL_REPLY_TO"]="GITLAB_EMAIL_REPLY_TO"
    val["GITLAB_CE_VERSION"]=ver
    expected=1; for (k in map) expected++
  }
  NR==FNR { i=index($0,"="); k=substr($0,1,i-1); if (k in map) val[map[k]]=substr($0,i+1); next }
  { i=index($0,"="); k=substr($0,1,i-1)
    if (k in val) {
      if (index(val[k], "\047")) { print "ERROR: " k " contains a single quote" > "/dev/stderr"; bad=1 }
      printf "%s=\047%s\047\n", k, val[k]; set[k]=1; next
    }
    print }
  END { n=0; for (k in set) { print "set " k > "/dev/stderr"; n++ }
        print n " of " expected " values set" > "/dev/stderr"; exit bad }
' - .env > .env.new

chmod --reference=.env .env.new
chown --reference=.env .env.new
mv .env.new .env
awk '/^(LDAP_BIND_PASSWORD|SMTP_PASSWORD)=/ { i=index($0,"="); print substr($0,1,i-1) " length:", length(substr($0,i+1))-2 }' .env
