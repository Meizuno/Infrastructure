#!/usr/bin/env bash
# Generate the Ed25519 private key the auth service signs access tokens with
# (JWT_SIGNING_ALG=EdDSA + JWT_PRIVATE_KEY_FILE). The key is mounted into the
# authentication container as a Docker secret and MUST NOT leave the host —
# secrets/ is gitignored. Idempotent: refuses to clobber an existing key so a
# stray run can't silently rotate the signer out from under live sessions.
#
#   ./scripts/gen-jwt-key.sh            # create secrets/jwt_private_key.pem
#   ./scripts/rotate-jwt-key.sh         # seamless rotation (overlap by kid)
set -euo pipefail
cd "$(dirname "$0")/.."

out="secrets/jwt_private_key.pem"
prev="secrets/jwt_previous_public_keys.pem"
# secrets/ is 0700 so no OTHER host user can enter it...
mkdir -p secrets && chmod 700 secrets

# The previous-public-keys bundle must always exist (even empty): compose mounts
# it into the container, and a missing source file fails `docker compose up`.
# It is empty in steady state and filled briefly by rotate-jwt-key.sh.
[ -f "$prev" ] || { : > "$prev"; }
chmod 644 "$prev"

if [ -f "$out" ]; then
  echo "$out already exists — refusing to overwrite." >&2
  echo "To rotate the signing key, use ./scripts/rotate-jwt-key.sh." >&2
  echo "(ensured $prev exists)"
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
