#!/usr/bin/env bash
# Manage the stack's secrets encrypted at rest with SOPS + age.
#
# The canonical, COMMITTED secrets are the *.enc.env files — values encrypted,
# keys readable, safe in git and in host backups/snapshots. The plaintext env
# files they decrypt to are derived, gitignored, 0600 artifacts that docker
# compose reads at runtime; the deploy pipeline regenerates them on every deploy.
#
#   secrets.enc.env           → .env           (shared stack secrets)
#   secrets.forma.enc.env     → forma.env      (forma app secrets; env_file)
#
# The age PRIVATE key (default ~/.config/sops/age/keys.txt) never leaves the
# host and is the only thing that can decrypt — back it up somewhere safe;
# losing it means losing every secret.
#
#   ./scripts/secrets.sh init          # one-time: make an age key, encrypt .env
#   ./scripts/secrets.sh edit [name]   # edit secrets in $EDITOR (re-encrypts on save)
#   ./scripts/secrets.sh decrypt       # materialize every plaintext env file (0600)
#   ./scripts/secrets.sh view [name]   # print decrypted secrets to stdout
#   ./scripts/secrets.sh rekey         # re-encrypt to current .sops.yaml recipients
#
# [name] selects a file: omit (or `main`) for secrets.enc.env, or an app name
# (e.g. `forma`) for secrets.<name>.enc.env.
set -euo pipefail
cd "$(dirname "$0")/.."

ENC=secrets.enc.env
PLAIN=.env
# enc:plaintext pairs for every managed secrets file. `decrypt`/`rekey` cover all
# that exist; add a line to give another app its own file.
PAIRS=(
  "secrets.enc.env:.env"
  "secrets.forma.enc.env:forma.env"
)
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ $1 not installed. $2" >&2; exit 1; }; }

# Resolve a [name] selector to its encrypted file.
enc_for() {
  case "${1:-}" in
    "" | main) echo "$ENC" ;;
    *)         echo "secrets.$1.enc.env" ;;
  esac
}

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
    echo "→ per-app files (e.g. secrets.forma.enc.env) are created with: $0 edit <name>"
    ;;
  edit)
    need sops "Install SOPS first (scripts/secrets.sh init explains how)."
    sops "$(enc_for "${2:-}")"
    ;;
  decrypt)
    need sops "Install SOPS first."
    for pair in "${PAIRS[@]}"; do
      enc="${pair%%:*}"; plain="${pair##*:}"
      [ -f "$enc" ] || continue
      ( umask 077; sops -d "$enc" > "$plain" )
      chmod 600 "$plain"
      echo "→ wrote $plain (0600) from $enc"
    done
    ;;
  view)
    need sops "Install SOPS first."
    sops -d "$(enc_for "${2:-}")"
    ;;
  rekey)
    need sops "Install SOPS first."
    for pair in "${PAIRS[@]}"; do
      enc="${pair%%:*}"
      [ -f "$enc" ] || continue
      sops updatekeys "$enc"
      echo "→ rekeyed $enc to the recipients in .sops.yaml"
    done
    ;;
  *)
    echo "usage: $0 {init|edit [name]|decrypt|view [name]|rekey}" >&2
    exit 1
    ;;
esac
