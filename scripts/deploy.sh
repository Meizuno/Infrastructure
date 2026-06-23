#!/usr/bin/env bash
# Zero-downtime deploy for the meizuno stack.
#
#   ./scripts/deploy.sh              # roll out ALL app services
#   ./scripts/deploy.sh ai-chat      # roll out a single service
#   ./scripts/deploy.sh notes ai-chat
#
# Infra (traefik, cloudflared, postgres, kuma, victoria-logs, vector) is
# reconciled with a plain `up -d`. App services are updated one at a time
# with `docker rollout`, which starts a second replica, waits for it to become
# healthy, then removes the old one — Traefik shifts traffic automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

INFRA="traefik cloudflared postgres kuma victoria-logs vector"
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
