#!/bin/bash
# Roles, databases and extensions GitLab needs (a superuser must create amcheck/btree_gist).
set -euo pipefail
psql -v ON_ERROR_STOP=1 -U postgres <<SQL
CREATE ROLE gitlab   LOGIN PASSWORD '${GITLAB_DB_PASSWORD}';
CREATE ROLE registry LOGIN PASSWORD '${REGISTRY_DB_PASSWORD}';
CREATE DATABASE gitlabhq_production OWNER gitlab;
CREATE DATABASE registry OWNER registry;
\c gitlabhq_production
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS amcheck;
SQL
