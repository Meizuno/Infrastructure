#!/usr/bin/env bash
# Verify a backup actually restores — into a THROWAWAY Postgres container, never
# the live database. Pulls the newest R2 dump (or the key passed as $1),
# restores it, and prints databases / login roles / per-DB table+row counts.
# Safe to run anytime; the temp container is removed on exit.
#
#   ./scripts/verify-restore.sh
#   ./scripts/verify-restore.sh postgres/meizuno-pgdumpall-20260628T033000Z.sql.gz.age
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-; }

R2_ENDPOINT="${R2_ENDPOINT:-$(env_val R2_ENDPOINT)}"
R2_BUCKET="${R2_BUCKET:-$(env_val R2_BUCKET)}"
R2_PREFIX="${R2_PREFIX:-$(env_val R2_PREFIX)}"; R2_PREFIX="${R2_PREFIX:-postgres}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-$(env_val R2_ACCESS_KEY_ID)}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-$(env_val R2_SECRET_ACCESS_KEY)}"
export AWS_DEFAULT_REGION=auto
# Backups are age-encrypted; decrypt with the SOPS age key on the host.
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
command -v age >/dev/null 2>&1 || { echo "age not installed — needed to decrypt the backup" >&2; exit 1; }
[ -f "$AGE_KEY_FILE" ] || { echo "age key not found at $AGE_KEY_FILE (set SOPS_AGE_KEY_FILE)" >&2; exit 1; }
: "${R2_ENDPOINT:?missing R2_ENDPOINT in $ENV_FILE}"
: "${R2_BUCKET:?missing R2_BUCKET in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY in $ENV_FILE}"

r2() { docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
         amazon/aws-cli "$@" --endpoint-url "$R2_ENDPOINT"; }

key="${1:-}"
if [ -z "$key" ]; then
  latest=$(r2 s3 ls "s3://${R2_BUCKET}/${R2_PREFIX}/" | awk '{print $NF}' | grep -E '\.sql\.gz\.age$' | sort | tail -n1)
  [ -n "$latest" ] || { echo "no .sql.gz.age under ${R2_PREFIX}/ in ${R2_BUCKET}" >&2; exit 1; }
  key="${R2_PREFIX}/${latest}"
fi
echo "Verifying restore of: ${key}"

tmp="$(mktemp)"
name="pg-restore-test-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -f "$tmp"; }
trap cleanup EXIT

r2 s3 cp "s3://${R2_BUCKET}/${key}" - > "$tmp"
[ -s "$tmp" ] || { echo "downloaded dump is empty" >&2; exit 1; }

echo "Starting throwaway Postgres (no published port, auto-removed)…"
docker run -d --name "$name" -e POSTGRES_PASSWORD=verify postgres:18.4-bookworm >/dev/null
for _ in $(seq 1 30); do
  docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

echo "Restoring (age -d → gunzip → psql)…"
age -d -i "$AGE_KEY_FILE" "$tmp" | gunzip | docker exec -i "$name" psql -q -U postgres -d postgres >/dev/null 2>/tmp/verify-restore.err || true

q() { docker exec "$name" psql -tAX -U postgres "$@"; }

echo "── databases ──"
q -d postgres -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1','postgres') ORDER BY 1;"
echo "── login roles ──"
q -d postgres -c "SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY 1;"
echo "── per-DB tables / rows ──"
for db in authentication money_manager recipes_book notes; do
  if q -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    docker exec "$name" psql -qX -U postgres -d "$db" -c "ANALYZE;" >/dev/null 2>&1 || true
    echo "  ${db}: $(q -d "$db" -c "SELECT count(*)||' tables, '||coalesce(sum(n_live_tup),0)||' rows' FROM pg_stat_user_tables;")"
  else
    echo "  ${db}: MISSING"
  fi
done

errs=$(grep -ciE 'error:' /tmp/verify-restore.err 2>/dev/null || true)
echo "Restore errors logged: ${errs:-0} (details: /tmp/verify-restore.err)"
echo "OK — throwaway instance removed on exit."
