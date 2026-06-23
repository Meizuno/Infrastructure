#!/usr/bin/env bash
# Installs the docker-rollout CLI plugin (https://github.com/wowu/docker-rollout)
# used by scripts/deploy.sh for zero-downtime rollouts.
set -euo pipefail

PLUGIN_DIR="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
mkdir -p "$PLUGIN_DIR"

curl -fsSL \
  https://raw.githubusercontent.com/wowu/docker-rollout/master/docker-rollout \
  -o "$PLUGIN_DIR/docker-rollout"
chmod +x "$PLUGIN_DIR/docker-rollout"

echo "✓ Installed docker-rollout → $PLUGIN_DIR/docker-rollout"
docker rollout --help >/dev/null 2>&1 && echo "✓ 'docker rollout' is available" \
  || echo "✗ 'docker rollout' not picked up — check that $PLUGIN_DIR is your docker cli-plugins dir"
