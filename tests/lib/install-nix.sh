#!/usr/bin/env bash
# Install Nix (multi-user) inside the test container; idempotent.
# The /nix docker volume caches the store across runs.
set -euo pipefail

if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates xz-utils sudo git findutils >/dev/null
  echo "== installing Nix (multi-user, with container systemd) =="
  curl -sSfL https://nixos.org/nix/install -o /tmp/nix-install.sh
  sh /tmp/nix-install.sh --daemon --yes
else
  echo "== Nix already present, ensuring daemon =="
  systemctl enable --now nix-daemon.service nix-daemon.socket 2>/dev/null || true
  systemctl start nix-daemon.service 2>/dev/null || true
fi

export PATH="/nix/var/nix/profiles/default/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"
echo "== nix $(nix --version) ready =="
