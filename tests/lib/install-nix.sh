#!/usr/bin/env bash
# Install Nix (multi-user) inside the test container; idempotent.
# The /nix docker volume caches the store across runs. NOTE: /etc/nix and the
# daemon units live in the container's ephemeral filesystem, so "Nix already
# present" is only a valid shortcut when the unit file survived too.
set -euo pipefail

if [ -x /nix/var/nix/profiles/default/bin/nix ] \
   && [ -f /etc/systemd/system/nix-daemon.service ] \
   && systemctl is-active --quiet nix-daemon.service; then
  echo "== Nix + daemon already running =="
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates xz-utils sudo git findutils iproute2 >/dev/null
  echo "== installing Nix (multi-user, with container systemd) =="
  curl -sSfL https://nixos.org/nix/install -o /tmp/nix-install.sh
  sh /tmp/nix-install.sh --daemon --yes
  systemctl enable --now nix-daemon.service nix-daemon.socket
fi

systemctl is-active --quiet nix-daemon.service || {
  echo "nix-daemon is not running" >&2; exit 1;
}

export PATH="/nix/var/nix/profiles/default/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"
echo "== nix $(nix --version) + daemon active =="
