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
# secrets/ is 0700 so no OTHER host user can enter it...
mkdir -p secrets && chmod 700 secrets
if [ -f "$out" ]; then
  echo "$out already exists — refusing to overwrite." >&2
  echo "To rotate the signing key: delete it, regenerate, then redeploy authentication." >&2
  exit 0
fi

umask 077
openssl genpkey -algorithm ed25519 -out "$out"
# ...but the file itself must be world-readable (o+r): docker bind-mounts it as a
# file secret into the authentication container, which runs as a NON-root uid,
# and non-Swarm compose does not remap secret ownership. 0644 inside a 0700 dir
# keeps it reachable only by this host user and the container — equivalent
# protection to 0600 against other host users, but readable by the container.
chmod 644 "$out"
echo "wrote $out (Ed25519 private key; file 0644 inside 0700 secrets/)"
echo
echo "public half (served at /.well-known/jwks.json once deployed):"
openssl pkey -in "$out" -pubout
