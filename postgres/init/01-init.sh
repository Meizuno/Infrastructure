#!/bin/bash
# Runs ONLY on a fresh data volume (Postgres entrypoint convention).
# Creates the shared `web` login role and the per-app databases it owns.
# Idempotent so it is safe to keep around.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_USER" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
      CREATE ROLE web LOGIN PASSWORD '${WEB_DB_PASSWORD}';
    END IF;
  END
  \$\$;
EOSQL

for db in authentication chat money_manager recipes_book notes; do
  if ! psql -tA --username "$POSTGRES_USER" --dbname "$POSTGRES_USER" \
        -c "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_USER" \
      -c "CREATE DATABASE $db OWNER web"
    echo "created database: $db"
  fi
done
