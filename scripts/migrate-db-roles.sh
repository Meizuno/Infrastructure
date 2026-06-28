#!/usr/bin/env bash
# One-time migration: move from the shared `web` role to one role per app on an
# EXISTING database (the init script only runs on a fresh volume).
#
# For each app it: creates the role (or resets its password to match the new
# DATABASE_URL), transfers DATABASE + object ownership from `web`, and confines
# CONNECT to that role only. Re-runnable.
#
# Reads the per-app passwords straight from the env file (default ./.env) — no
# `source`, so a `$` in a value is taken literally instead of being mangled by
# the shell. Run from the stack dir AFTER `git pull` but BEFORE redeploying the
# apps:
#
#   ./scripts/migrate-db-roles.sh                 # uses ./.env
#   ENV_FILE=/path/to/.env ./scripts/migrate-db-roles.sh
#
# Once the apps are redeployed and healthy you can drop the old role:
#   docker compose exec postgres psql -U admin -d admin -c 'DROP ROLE web;'
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
# Read a KEY's raw value from the env file without shell-evaluating it, so a `$`
# in the value stays literal (unlike `source`). Takes everything after the first
# `=`, so values may contain `=`.
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-; }

SU="${POSTGRES_SUPERUSER:-$(env_val POSTGRES_SUPERUSER)}"; SU="${SU:-admin}"
AUTH_DB_PASSWORD="${AUTH_DB_PASSWORD:-$(env_val AUTH_DB_PASSWORD)}"
MONEY_DB_PASSWORD="${MONEY_DB_PASSWORD:-$(env_val MONEY_DB_PASSWORD)}"
RECIPES_DB_PASSWORD="${RECIPES_DB_PASSWORD:-$(env_val RECIPES_DB_PASSWORD)}"
NOTES_DB_PASSWORD="${NOTES_DB_PASSWORD:-$(env_val NOTES_DB_PASSWORD)}"

psql() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$SU" "$@"; }

: "${AUTH_DB_PASSWORD:?missing AUTH_DB_PASSWORD in $ENV_FILE}"
: "${MONEY_DB_PASSWORD:?missing MONEY_DB_PASSWORD in $ENV_FILE}"
: "${RECIPES_DB_PASSWORD:?missing RECIPES_DB_PASSWORD in $ENV_FILE}"
: "${NOTES_DB_PASSWORD:?missing NOTES_DB_PASSWORD in $ENV_FILE}"

web_exists=$(psql -tA -d "$SU" -c "SELECT 1 FROM pg_roles WHERE rolname='web'" | tr -d '[:space:]')

# migrate <db> <role> <password>
migrate() {
  local db="$1" role="$2" pass="$3"
  psql -d "$SU" <<-SQL
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${role}') THEN
        CREATE ROLE "${role}" LOGIN PASSWORD '${pass}';
      ELSE
        ALTER ROLE "${role}" WITH LOGIN PASSWORD '${pass}';
      END IF;
    END \$\$;
    ALTER DATABASE "${db}" OWNER TO "${role}";
    REVOKE CONNECT ON DATABASE "${db}" FROM PUBLIC;
    GRANT CONNECT ON DATABASE "${db}" TO "${role}";
SQL
  # Reassign every object still owned by `web` inside this DB (tables, sequences,
  # the public schema) to the app role — must run connected to the DB itself.
  if [ "$web_exists" = "1" ]; then
    psql -d "$db" -c "REASSIGN OWNED BY web TO \"${role}\";"
  fi
  echo "migrated ${db} -> ${role}"
}

migrate authentication auth_user    "$AUTH_DB_PASSWORD"
migrate money_manager  money_user   "$MONEY_DB_PASSWORD"
migrate recipes_book   recipes_user "$RECIPES_DB_PASSWORD"
migrate notes          notes_user   "$NOTES_DB_PASSWORD"

echo "Done. Redeploy the apps, verify they're healthy, then: DROP ROLE web;"
