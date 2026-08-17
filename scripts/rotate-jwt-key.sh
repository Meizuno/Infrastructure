#!/usr/bin/env bash
# Seamless rotation of the EdDSA access-token signing key — zero failed
# validations. Because the auth service can verify against several public keys by
# kid, we overlap the old and new keys for one access-token TTL (15 min):
#
#   1. ./scripts/rotate-jwt-key.sh            # keep old PUBLIC key, mint a new
#                                             #   signing key, then REDEPLOY auth
#   2. wait > 15 min                          # in-flight old-key tokens expire
#   3. ./scripts/rotate-jwt-key.sh --finalize # drop the old key, then REDEPLOY
#
# During the overlap the auth service signs with the NEW key and still verifies
# the OLD one; both are published at /.well-known/jwks.json (by kid). The old
# PRIVATE key is discarded immediately — only its public half is retained, and
# only to verify already-issued tokens.
set -euo pipefail
cd "$(dirname "$0")/.."

key="secrets/jwt_private_key.pem"
prev="secrets/jwt_previous_public_keys.pem"
mkdir -p secrets && chmod 700 secrets

if [ "${1:-}" = "--finalize" ]; then
  : > "$prev"
  chmod 644 "$prev"
  echo "→ cleared $prev (old keys retired)."
  echo "  Redeploy to stop accepting them:  docker rollout authentication"
  exit 0
fi

[ -f "$key" ] || { echo "✗ $key not found — run ./scripts/gen-jwt-key.sh first." >&2; exit 1; }

# Retain the CURRENT key's public half so tokens it already signed keep verifying
# (the signer de-duplicates by kid, so re-running is safe).
[ -f "$prev" ] || : > "$prev"
openssl pkey -in "$key" -pubout >> "$prev"
chmod 644 "$prev"

# Mint a fresh signing key (the old private key is now discarded).
umask 077
openssl genpkey -algorithm ed25519 -out "$key.new"
mv -f "$key.new" "$key"
chmod 644 "$key"

echo "→ rotated: new signing key in $key; previous public key kept in $prev"
echo "→ new public half:"
openssl pkey -in "$key" -pubout
echo
echo "Next:"
echo "  1. docker rollout authentication           # start signing with the new key (both accepted)"
echo "  2. wait > 15 min                           # old-key access tokens expire"
echo "  3. ./scripts/rotate-jwt-key.sh --finalize  # then docker rollout authentication"
