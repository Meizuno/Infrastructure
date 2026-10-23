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
# `|| true`: a key that is not in the file is empty, not fatal. Without it a
# missing key failed the pipeline, and under pipefail and set -e that ended the
# script silently — so the keys with defaults below were never optional.
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

R2_ENDPOINT="${R2_ENDPOINT:-$(env_val R2_ENDPOINT)}"
R2_BUCKET="${R2_BUCKET:-$(env_val R2_BUCKET)}"
R2_PREFIX="${R2_PREFIX:-$(env_val R2_PREFIX)}"; R2_PREFIX="${R2_PREFIX:-postgres}"
# The live cluster's first superuser — POSTGRES_USER of the stack's postgres,
# the role pg_dumpall ran as. See the throwaway server below for why it matters.
SU="${POSTGRES_SUPERUSER:-$(env_val POSTGRES_SUPERUSER)}"; SU="${SU:-admin}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-$(env_val R2_ACCESS_KEY_ID)}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-$(env_val R2_SECRET_ACCESS_KEY)}"
export AWS_DEFAULT_REGION=auto
# Backups are age-encrypted; decrypt with the SOPS age key on the host.
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME:-/home/debian}/.config/sops/age/keys.txt}"
command -v age >/dev/null 2>&1 || { echo "age not installed — needed to decrypt the backup" >&2; exit 1; }
[ -f "$AGE_KEY_FILE" ] || { echo "age key not found at $AGE_KEY_FILE (set SOPS_AGE_KEY_FILE)" >&2; exit 1; }
: "${R2_ENDPOINT:?missing R2_ENDPOINT in $ENV_FILE}"
: "${R2_BUCKET:?missing R2_BUCKET in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY in $ENV_FILE}"

r2() { docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
         amazon/aws-cli "$@" --endpoint-url "$R2_ENDPOINT"; }

# Why it failed, in one line, for whoever called us: backup-db.sh puts it in
# the Kuma message, which used to say only "verify-failed-1". The first reason
# wins — the rest are usually its consequences.
because() {
  [ -n "${VERIFY_REASON_FILE:-}" ] || return 0
  [ -s "$VERIFY_REASON_FILE" ] || printf '%s\n' "$1" > "$VERIFY_REASON_FILE"
}

key="${1:-}"
if [ -z "$key" ]; then
  latest=$(r2 s3 ls "s3://${R2_BUCKET}/${R2_PREFIX}/" | awk '{print $NF}' | grep -E '\.sql\.gz\.age$' | sort | tail -n1)
  [ -n "$latest" ] || { echo "no .sql.gz.age under ${R2_PREFIX}/ in ${R2_BUCKET}" >&2; exit 1; }
  key="${R2_PREFIX}/${latest}"
fi
echo "Verifying restore of: ${key}"

tmp="$(mktemp)"
errlog="$(mktemp)"   # per-run, owned by us — a fixed /tmp path breaks when a
                     # previous run (different user) left it non-writable
name="pg-restore-test-$$"
# -v, or the restored copy stays on disk. The image declares a VOLUME, so the
# throwaway server writes the whole restored cluster into an anonymous volume,
# and `docker rm` without -v leaves it behind — one full copy of the databases
# per night (1.7 GB each on the host, found as a row of unattached volumes),
# and 40 MB for every night the restore never started.
cleanup() { docker rm -f -v "$name" >/dev/null 2>&1 || true; rm -f "$tmp" "$errlog"; }
trap cleanup EXIT

r2 s3 cp "s3://${R2_BUCKET}/${key}" - > "$tmp"
[ -s "$tmp" ] || { echo "downloaded dump is empty" >&2; exit 1; }

echo "Starting throwaway Postgres (no published port, auto-removed)…"
# Created with the live cluster's superuser as its FIRST user, as a real
# restore into a fresh stack would be, rather than the image's `postgres`.
# The dump records who granted each role membership — "GRANT pg_monitor TO
# monitoring … GRANTED BY admin" — and only the cluster's first superuser may
# grant as itself without an explicit admin option. Restored under `postgres`,
# admin is an ordinary superuser, so that line fails ("permission denied to
# grant privileges as role admin"), the membership is lost, and a good backup
# is reported as broken. Which is what the 23 October failure was, from the
# day the monitoring role was created.
docker run -d --name "$name" -e POSTGRES_USER="$SU" -e POSTGRES_PASSWORD=verify postgres:18.4-bookworm >/dev/null
# Ready over TCP, never over the socket. On a fresh volume the image's
# entrypoint runs a TEMPORARY server on the Unix socket only, runs initdb's
# scripts against it, stops it and starts the real one. pg_isready on the socket
# says yes to the temporary one, and a restore started then lands in the gap —
# "connection to server on socket … failed", nothing restored, and a FAIL for a
# backup that was fine. One cause of the intermittent "verify-failed-1":
# reproduced 2 runs in 12 waiting on the socket, 0 in 12 waiting on TCP, which
# only the real server listens on.
#
# And a server that never came up is a failure in its own right, said as one,
# rather than a restore attempted against nothing.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$name" pg_isready -h 127.0.0.1 -U "$SU" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  because "throwaway Postgres never became ready"
  echo "throwaway Postgres never became ready" >&2
  exit 1
fi

echo "Restoring (age -d → gunzip → psql)…"
age -d -i "$AGE_KEY_FILE" "$tmp" | gunzip | docker exec -i "$name" psql -q -U "$SU" -d postgres >/dev/null 2>"$errlog" || true

q() { docker exec "$name" psql -tAX -U "$SU" "$@"; }

echo "── databases ──"
q -d postgres -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1','postgres') ORDER BY 1;"
echo "── login roles ──"
q -d postgres -c "SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY 1;"
echo "── per-DB tables / rows ──"
# Verdict gate (exit code): FAIL if an expected DB is absent, a DB restored no
# tables, or psql logged a non-benign error. Lets a caller (backup-db.sh) treat
# a green Kuma ping as "backup uploaded AND provably restorable".
fail=0
for db in authentication money_manager recipes_book notes forma; do
  if q -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    docker exec "$name" psql -qX -U "$SU" -d "$db" -c "ANALYZE;" >/dev/null 2>&1 || true
    tbls=$(q -d "$db" -c "SELECT count(*) FROM pg_stat_user_tables;")
    rows=$(q -d "$db" -c "SELECT coalesce(sum(n_live_tup),0) FROM pg_stat_user_tables;")
    echo "  ${db}: ${tbls:-0} tables, ${rows:-0} rows"
    [ "${tbls:-0}" -gt 0 ] || { echo "    ✗ ${db} restored 0 tables"; because "${db} restored 0 tables"; fail=1; }
  else
    echo "  ${db}: MISSING"; because "${db} missing from the restore"; fail=1
  fi
done

# Count real psql errors, ignoring the benign "already exists" a pg_dumpall can
# emit for pre-seeded roles/objects in a fresh cluster.
errs=$(grep -iE 'error:' "$errlog" 2>/dev/null | grep -ivc 'already exists' || true)
if [ "${errs:-0}" -gt 0 ]; then
  echo "✗ ${errs} restore error(s):"
  grep -iE 'error:' "$errlog" | grep -iv 'already exists' | head -20
  because "${errs} restore error(s): $(grep -iE 'error:' "$errlog" | grep -iv 'already exists' | head -1 | cut -c1-120)"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS — backup restores cleanly (throwaway instance removed on exit)."
else
  echo "FAIL — backup did NOT verify; treat this backup as suspect." >&2
fi
exit "$fail"
