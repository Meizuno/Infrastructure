#!/usr/bin/env bash
# Off-host backup: pg_dumpall the stack's Postgres (roles + EVERY database) and
# stream it gzipped to Cloudflare R2 (S3-compatible). Meant to be run by a
# systemd timer (see systemd/) or cron. Reads config from ./.env (default).
#
#   ./scripts/backup-db.sh
#   ENV_FILE=/path/.env ./scripts/backup-db.sh
#
# Restore (DESTRUCTIVE — into a fresh/empty instance):
#   aws s3 cp s3://$R2_BUCKET/<key> - --endpoint-url $R2_ENDPOINT \
#     | gunzip | docker compose exec -T postgres psql -U admin -d postgres
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="${ENV_FILE:-.env}"
# Raw value after the first `=` — no shell eval, so `$`/`=` in secrets survive.
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-; }

SU="${POSTGRES_SUPERUSER:-$(env_val POSTGRES_SUPERUSER)}"; SU="${SU:-admin}"
R2_ENDPOINT="${R2_ENDPOINT:-$(env_val R2_ENDPOINT)}"
R2_BUCKET="${R2_BUCKET:-$(env_val R2_BUCKET)}"
R2_PREFIX="${R2_PREFIX:-$(env_val R2_PREFIX)}"; R2_PREFIX="${R2_PREFIX:-postgres}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-$(env_val R2_ACCESS_KEY_ID)}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-$(env_val R2_SECRET_ACCESS_KEY)}"
export AWS_DEFAULT_REGION=auto   # R2 ignores region but the CLI needs one set

: "${R2_ENDPOINT:?missing R2_ENDPOINT in $ENV_FILE}"
: "${R2_BUCKET:?missing R2_BUCKET in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY in $ENV_FILE}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
key="${R2_PREFIX}/meizuno-pgdumpall-${ts}.sql.gz"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

echo "[$(date -u +%FT%TZ)] dumping all databases…"
# Local socket inside the container → trust auth, no password needed.
docker compose exec -T postgres pg_dumpall -U "$SU" | gzip > "$tmp"
size=$(wc -c < "$tmp")
[ "$size" -gt 0 ] || { echo "dump is empty — aborting (not uploading)" >&2; exit 1; }

echo "[$(date -u +%FT%TZ)] uploading ${size} bytes → r2://${R2_BUCKET}/${key}"
docker run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
  -v "$tmp:/dump.sql.gz:ro" \
  amazon/aws-cli s3 cp /dump.sql.gz "s3://${R2_BUCKET}/${key}" \
  --endpoint-url "$R2_ENDPOINT"

echo "[$(date -u +%FT%TZ)] backup complete: ${key}"
