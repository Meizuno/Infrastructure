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

# cloudflared uses QUIC (UDP). The kernel's default UDP receive buffer is too
# small — quic-go warns ("failed to sufficiently increase receive buffer size")
# and can drop packets under load. Raise it once, persisted; net.core.*mem_max
# are host-global (not namespaced), so the tunnel container inherits the ceiling.
# https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
SYSCTL_FILE=/etc/sysctl.d/99-cloudflared-quic.conf
if [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; then
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo
  printf 'net.core.rmem_max=7500000\nnet.core.wmem_max=7500000\n' | $SUDO tee "$SYSCTL_FILE" >/dev/null
  $SUDO sysctl -q -p "$SYSCTL_FILE" && echo "✓ UDP buffers raised for cloudflared QUIC ($SYSCTL_FILE)"
else
  echo "! Raise UDP buffers manually for cloudflared QUIC:"
  echo "    echo 'net.core.rmem_max=7500000' | sudo tee $SYSCTL_FILE"
  echo "    echo 'net.core.wmem_max=7500000' | sudo tee -a $SYSCTL_FILE && sudo sysctl -p $SYSCTL_FILE"
fi
