#!/usr/bin/env bash
# Off-host backup: pg_dumpall the stack's Postgres (roles + EVERY database),
# gzip it, ENCRYPT it client-side with age, and stream it to Cloudflare R2
# (S3-compatible). R2 only ever stores ciphertext, so a leaked R2 token cannot
# read the data or the role password hashes. Meant to run from a systemd timer
# (see systemd/) or cron. Reads config from ./.env (default).
#
#   ./scripts/backup-db.sh
#   ENV_FILE=/path/.env ./scripts/backup-db.sh
#
# Restore (DESTRUCTIVE — into a fresh/empty instance), decrypt with the age key:
#   aws s3 cp s3://$R2_BUCKET/<key> - --endpoint-url $R2_ENDPOINT \
#     | age -d -i ~/.config/sops/age/keys.txt | gunzip \
#     | docker compose exec -T postgres psql -U admin -d postgres
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

# age recipient (public key) the dump is encrypted to. Explicit via
# BACKUP_AGE_RECIPIENT, else derived from the SOPS age key on the host.
# ${HOME:-…} keeps this from tripping `set -u` when systemd runs us without HOME.
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME:-/home/debian}/.config/sops/age/keys.txt}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-$(env_val BACKUP_AGE_RECIPIENT)}"
if [ -z "$BACKUP_AGE_RECIPIENT" ] && [ -f "$AGE_KEY_FILE" ]; then
  BACKUP_AGE_RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || true)"
fi

# Optional Uptime-Kuma push monitor: pinged "up" on success, "down" on failure,
# so a failed backup OR a timer that never fired both raise an alert. Kuma sits
# behind Cloudflare Access with no host port, so reach its push endpoint over the
# docker network — KUMA_PUSH_URL is the INTERNAL form:
#   http://uptime-kuma:3001/api/push/<token>
KUMA_PUSH_URL="${KUMA_PUSH_URL:-$(env_val KUMA_PUSH_URL)}"
ping_kuma() {
  [ -n "$KUMA_PUSH_URL" ] || return 0
  docker run --rm --network meizuno_edge curlimages/curl:latest \
    -fsS --max-time 10 "${KUMA_PUSH_URL}?status=$1&msg=$2" >/dev/null 2>&1 || true
}

tmp=""
stage="init"
finish() {
  code=$?
  [ -n "$tmp" ] && rm -f "$tmp"
  # "up" only after the backup is uploaded AND verified restorable (see below),
  # so a green Kuma monitor means recoverable, not merely "upload didn't error".
  if [ "$code" -eq 0 ]; then ping_kuma up ok; else ping_kuma down "${stage}-failed-${code}"; fi
}
trap finish EXIT

: "${R2_ENDPOINT:?missing R2_ENDPOINT in $ENV_FILE}"
: "${R2_BUCKET:?missing R2_BUCKET in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY in $ENV_FILE}"
command -v age >/dev/null 2>&1 || { echo "age not installed — required to encrypt the backup" >&2; exit 1; }
: "${BACKUP_AGE_RECIPIENT:?no age recipient (set BACKUP_AGE_RECIPIENT in $ENV_FILE or provide $AGE_KEY_FILE)}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
key="${R2_PREFIX}/meizuno-pgdumpall-${ts}.sql.gz.age"
tmp="$(mktemp)"

stage="dump"
echo "[$(date -u +%FT%TZ)] dumping all databases (gzip → age)…"
# Local socket inside the container → trust auth, no password needed. pipefail
# (set above) aborts if pg_dumpall fails mid-stream, so a broken dump is never
# uploaded. The plaintext never touches disk — it is encrypted in the pipe.
docker compose exec -T postgres pg_dumpall -U "$SU" | gzip | age -r "$BACKUP_AGE_RECIPIENT" > "$tmp"
size=$(wc -c < "$tmp")
[ "$size" -gt 0 ] || { echo "encrypted dump is empty — aborting (not uploading)" >&2; exit 1; }

stage="upload"
echo "[$(date -u +%FT%TZ)] uploading ${size} bytes (encrypted) → r2://${R2_BUCKET}/${key}"
docker run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
  -v "$tmp:/dump.sql.gz.age:ro" \
  amazon/aws-cli s3 cp /dump.sql.gz.age "s3://${R2_BUCKET}/${key}" \
  --endpoint-url "$R2_ENDPOINT"

# Prove the object we just wrote to R2 is actually THIS run's backup and is
# restorable — not a stale/previous object left in place by a silent no-op or a
# truncated upload. Two gates, both against the exact key we just wrote:
#   (a) byte-for-byte: R2 ContentLength must equal the local artifact's size, so
#       verify can never "pass" on an older object than this run produced;
#   (b) round-trip restore into a THROWAWAY Postgres (never the live DB).
# set -e aborts here on any mismatch/failure, so the Kuma ping reflects a fresh,
# recoverable backup — not merely a successful upload.
stage="verify"
echo "[$(date -u +%FT%TZ)] checking R2 object is this run's backup (size match)…"
remote_size=$(docker run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
  amazon/aws-cli s3api head-object --bucket "$R2_BUCKET" --key "$key" \
  --endpoint-url "$R2_ENDPOINT" --query ContentLength --output text)
[ "$remote_size" = "$size" ] || { echo "R2 object is ${remote_size} bytes but this run produced ${size} — not our backup, aborting" >&2; exit 1; }

echo "[$(date -u +%FT%TZ)] verifying the uploaded backup restores…"
"$(dirname "$0")/verify-restore.sh" "$key"

echo "[$(date -u +%FT%TZ)] backup complete & verified restorable: ${key}"
