#!/usr/bin/env bash
# One-time migration: rename the `calories` app to `forma` on an EXISTING
# cluster. postgres/init/01-init.sh only runs on a fresh volume, so on a live
# stack the database and role keep their old names until this runs.
#
# It renames the DATABASE and the login ROLE in place (no dump/restore, so the
# data never moves) and sets the role's password to FORMA_DB_PASSWORD from the
# env file. Re-runnable: if the new names are already there it reports and exits
# clean, so it is safe to run twice.
#
# ORDER MATTERS. Run from the stack dir AFTER `git pull` but BEFORE `docker
# compose up -d` — the new compose file points at postgres://forma_user@.../forma
# and the app will not start until these exist:
#
#   ./scripts/secrets.sh decrypt                  # writes .env + forma.env
#   ./scripts/rename-calories-to-forma.sh         # uses ./.env
#   docker compose up -d forma
#
# Renaming a DATABASE needs no other session connected to it, so stop the app
# first (`docker compose stop calories` on the old stack, or `rm -f` it).
#
#   ENV_FILE=/path/to/.env ./scripts/rename-calories-to-forma.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
# Read a KEY's raw value without shell-evaluating it, so a `$` in the value
# stays literal (same approach as migrate-db-roles.sh).
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-; }

SU="${POSTGRES_SUPERUSER:-$(env_val POSTGRES_SUPERUSER)}"; SU="${SU:-admin}"
FORMA_DB_PASSWORD="${FORMA_DB_PASSWORD:-$(env_val FORMA_DB_PASSWORD)}"
: "${FORMA_DB_PASSWORD:?missing FORMA_DB_PASSWORD in $ENV_FILE}"

psql() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$SU" "$@"; }
exists() { psql -tA -d "$SU" -c "$1" | tr -d '[:space:]'; }

db_old=$(exists "SELECT 1 FROM pg_database WHERE datname='calories'")
db_new=$(exists "SELECT 1 FROM pg_database WHERE datname='forma'")
role_old=$(exists "SELECT 1 FROM pg_roles WHERE rolname='calories_user'")
role_new=$(exists "SELECT 1 FROM pg_roles WHERE rolname='forma_user'")

if [ "$db_new" = "1" ] && [ "$role_new" = "1" ]; then
  echo "already migrated: database forma + role forma_user exist — nothing to do"
  exit 0
fi

# Refuse to guess if the cluster is in a shape this script didn't expect.
if [ "$db_old" != "1" ] && [ "$db_new" != "1" ]; then
  echo "neither 'calories' nor 'forma' database exists — is this the right cluster?" >&2
  exit 1
fi

# A DATABASE can only be renamed with no other session connected to it.
if [ "$db_old" = "1" ]; then
  conns=$(exists "SELECT count(*) FROM pg_stat_activity WHERE datname='calories'")
  if [ "${conns:-0}" -gt 0 ]; then
    echo "'calories' still has ${conns} open connection(s) — stop the app first:" >&2
    echo "  docker compose stop calories  # or: docker compose rm -sf calories" >&2
    exit 1
  fi
fi

# Role first: renaming it while it owns the DB is fine, ownership follows the OID.
if [ "$role_old" = "1" ] && [ "$role_new" != "1" ]; then
  psql -d "$SU" -c 'ALTER ROLE calories_user RENAME TO forma_user;'
  echo "renamed role calories_user -> forma_user"
fi
# RENAME clears the password (it is salted with the role name), so always reset it.
psql -d "$SU" -c "ALTER ROLE forma_user WITH LOGIN PASSWORD '${FORMA_DB_PASSWORD}';"
echo "set forma_user password from ${ENV_FILE}"

if [ "$db_old" = "1" ] && [ "$db_new" != "1" ]; then
  psql -d "$SU" -c 'ALTER DATABASE calories RENAME TO forma;'
  echo "renamed database calories -> forma"
fi

# Re-apply the confinement the init script sets up, against the new names.
psql -d "$SU" -c 'REVOKE CONNECT ON DATABASE forma FROM PUBLIC;'
psql -d "$SU" -c 'GRANT CONNECT ON DATABASE forma TO forma_user;'

echo "Done. Now: docker compose up -d forma  (and drop the old calories container)"
