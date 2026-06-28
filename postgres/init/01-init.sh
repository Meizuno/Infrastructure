#!/bin/bash
# Runs ONLY on a fresh data volume (Postgres entrypoint convention).
#
# One login role per app, each OWNING only its own database and able to CONNECT
# only to it. PUBLIC's default CONNECT is revoked, so a single leaked app
# password is confined to that one app's data — a compromised app can't read,
# write, or drop another app's schema.
#
# For an EXISTING database (this script won't run), use
# scripts/migrate-db-roles.sh to move off the old shared `web` role.
#
# Idempotent so it is safe to keep around.
set -euo pipefail

psql_admin() {
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_USER" "$@"
}

# create_app <db> <role> <password>
create_app() {
  local db="$1" role="$2" pass="$3"

  psql_admin <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') THEN
        CREATE ROLE "${role}" LOGIN PASSWORD '${pass}';
      END IF;
    END
    \$\$;
EOSQL

  if ! psql_admin -tA -c "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
    psql_admin -c "CREATE DATABASE \"${db}\" OWNER \"${role}\""
    echo "created database: ${db} (owner ${role})"
  fi

  # Confine the role to its own database (the superuser always bypasses this).
  psql_admin -c "REVOKE CONNECT ON DATABASE \"${db}\" FROM PUBLIC"
  psql_admin -c "GRANT CONNECT ON DATABASE \"${db}\" TO \"${role}\""
}

create_app authentication auth_user    "${AUTH_DB_PASSWORD}"
create_app money_manager  money_user   "${MONEY_DB_PASSWORD}"
create_app recipes_book   recipes_user "${RECIPES_DB_PASSWORD}"
create_app notes          notes_user   "${NOTES_DB_PASSWORD}"
