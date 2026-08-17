#!/usr/bin/env bash
# Manage the stack's secrets encrypted at rest with SOPS + age.
#
# The canonical, COMMITTED secrets file is secrets.enc.env — values encrypted,
# keys readable, safe in git and in host backups/snapshots. The plaintext .env
# is a derived, gitignored, 0600 artifact that docker compose reads at runtime;
# the deploy pipeline regenerates it from the encrypted source on every deploy.
#
# The age PRIVATE key (default ~/.config/sops/age/keys.txt) never leaves the
# host and is the only thing that can decrypt — back it up somewhere safe;
# losing it means losing every secret.
#
#   ./scripts/secrets.sh init       # one-time: make an age key, encrypt .env
#   ./scripts/secrets.sh edit       # edit secrets in $EDITOR (re-encrypts on save)
#   ./scripts/secrets.sh decrypt    # materialize .env from secrets.enc.env (0600)
#   ./scripts/secrets.sh view       # print decrypted secrets to stdout
#   ./scripts/secrets.sh rekey      # re-encrypt to current .sops.yaml recipients
set -euo pipefail
cd "$(dirname "$0")/.."

ENC=secrets.enc.env
PLAIN=.env
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ $1 not installed. $2" >&2; exit 1; }; }

case "${1:-}" in
  init)
    need sops "Install: https://github.com/getsops/sops/releases"
    need age-keygen "Install age: https://github.com/FiloSottile/age"
    if [ ! -f "$AGE_KEY_FILE" ]; then
      mkdir -p "$(dirname "$AGE_KEY_FILE")"
      ( umask 077; age-keygen -o "$AGE_KEY_FILE" )
      echo "→ generated age key at $AGE_KEY_FILE — BACK IT UP (losing it loses the secrets)"
    else
      echo "→ reusing existing age key at $AGE_KEY_FILE"
    fi
    pub=$(grep -oE 'age1[0-9a-z]+' "$AGE_KEY_FILE" | head -n1)
    [ -n "$pub" ] || { echo "✗ could not read a public key from $AGE_KEY_FILE" >&2; exit 1; }
    cat > .sops.yaml <<EOF
# SOPS encrypts the VALUES in *.env files for the recipient(s) below; keys stay
# readable. Commit this file. Regenerate with: ./scripts/secrets.sh init
creation_rules:
  - path_regex: \.env\$
    age: $pub
EOF
    echo "→ wrote .sops.yaml (recipient $pub) — commit it"
    if [ -f "$ENC" ]; then
      echo "→ $ENC already exists; leaving it. Use 'edit' to change secrets."
    elif [ -f "$PLAIN" ]; then
      sops -e --input-type dotenv --output-type dotenv "$PLAIN" > "$ENC"
      echo "→ encrypted $PLAIN → $ENC. Commit $ENC; $PLAIN stays gitignored."
    else
      echo "→ no $PLAIN found. Create it from .env.example, then run 'init' again."
    fi
    ;;
  edit)
    need sops "Install SOPS first (scripts/secrets.sh init explains how)."
    sops "$ENC"
    ;;
  decrypt)
    need sops "Install SOPS first."
    ( umask 077; sops -d "$ENC" > "$PLAIN" )
    chmod 600 "$PLAIN"
    echo "→ wrote $PLAIN (0600) from $ENC"
    ;;
  view)
    need sops "Install SOPS first."
    sops -d "$ENC"
    ;;
  rekey)
    need sops "Install SOPS first."
    sops updatekeys "$ENC"
    echo "→ rekeyed $ENC to the recipients in .sops.yaml"
    ;;
  *)
    echo "usage: $0 {init|edit|decrypt|view|rekey}" >&2
    exit 1
    ;;
esac
