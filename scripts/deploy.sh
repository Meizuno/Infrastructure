#!/usr/bin/env bash
# Zero-downtime deploy for the meizuno stack.
#
#   ./scripts/deploy.sh              # roll out ALL app services
#   ./scripts/deploy.sh ai-chat      # roll out a single service
#   ./scripts/deploy.sh notes ai-chat
#
# Infra (traefik, cloudflared, postgres, kuma, victoria-logs, vector, beszel +
# beszel-agent) is reconciled with a plain `up -d`. App services are updated one
# at a time
# with `docker rollout`, which starts a second replica, waits for it to become
# healthy, then removes the old one — Traefik shifts traffic automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

# Secrets are SOPS-encrypted at rest (secrets.enc.env). Materialize the
# gitignored .env that docker compose reads. No-op if SOPS isn't adopted yet.
if [ -f secrets.enc.env ]; then
  command -v sops >/dev/null 2>&1 || { echo "✗ secrets.enc.env present but sops is not installed — see scripts/secrets.sh" >&2; exit 1; }
  ( umask 077; sops -d secrets.enc.env > .env ) && chmod 600 .env
fi

INFRA="traefik cloudflared postgres kuma victoria-logs vector beszel beszel-agent"
ALL_APPS="authentication ai-chat money-manager recipes-book notes"

if ! docker rollout --help >/dev/null 2>&1; then
  echo "✗ docker-rollout plugin not found. Run scripts/install-prereqs.sh first." >&2
  exit 1
fi

APPS="${*:-$ALL_APPS}"

echo "→ Pulling images..."
docker compose pull $INFRA $APPS

echo "→ Reconciling infra..."
docker compose up -d $INFRA

for svc in $APPS; do
  echo "→ Rolling out $svc (zero downtime)..."
  docker rollout "$svc"
done

echo "✓ Deploy complete: $APPS"
