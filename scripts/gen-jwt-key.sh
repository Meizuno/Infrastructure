#!/usr/bin/env bash
# Generate the Ed25519 private key the auth service signs access tokens with
# (JWT_SIGNING_ALG=EdDSA + JWT_PRIVATE_KEY_FILE). The key is mounted into the
# authentication container as a Docker secret and MUST NOT leave the host —
# secrets/ is gitignored. Idempotent: refuses to clobber an existing key so a
# stray run can't silently rotate the signer out from under live sessions.
#
#   ./scripts/gen-jwt-key.sh            # create secrets/jwt_private_key.pem
#   rm secrets/jwt_private_key.pem && ./scripts/gen-jwt-key.sh   # rotate
set -euo pipefail
cd "$(dirname "$0")/.."

out="secrets/jwt_private_key.pem"
mkdir -p secrets
if [ -f "$out" ]; then
  echo "$out already exists — refusing to overwrite." >&2
  echo "To rotate the signing key: delete it, regenerate, then redeploy authentication." >&2
  exit 0
fi

umask 077
openssl genpkey -algorithm ed25519 -out "$out"
chmod 600 "$out"
echo "wrote $out (Ed25519 private key, 0600)"
echo
echo "public half (served at /.well-known/jwks.json once deployed):"
openssl pkey -in "$out" -pubout
