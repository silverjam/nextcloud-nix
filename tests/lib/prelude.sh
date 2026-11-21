#!/usr/bin/env bash
# Streamed into the test container before every scenario.
# Provides: environment, nix profile, assertion helpers.
set -euo pipefail
export PATH="/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NIX_CONFIG="experimental-features = nix-command flakes"
export BASE_URL="http://127.0.0.1:55555"
cd /test

step() { echo; echo "== $* =="; }
ok()   { echo "  OK  $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

expect_equal() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (expected '$1', got '$2')"; fi
}

# assert core services + init + http + a working admin web login
install_and_assert() {
  step "nix run .#deploy (installs unit files, starts services)"
  nix run .#deploy

  step "units active"
  for u in nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init; do
    systemctl is-active --quiet "$u" || fail "$u not active"
  done
  ok "db/fpm/caddy/init active"

  step "unit files pass systemd-analyze verify (container systemd = prod family)"
  systemd-analyze verify /etc/systemd/system/nextcloud-*.service \
                         /etc/systemd/system/nextcloud-*.timer
  ok "verify clean"

  step "status.php"
  local out=""
  for _ in $(seq 1 30); do
    out="$(curl -s -m 5 "$BASE_URL/status.php" || true)"
    echo "$out" | grep -q '"installed":true' && break
    sleep 1
  done
  echo "$out" | grep -q '"installed":true' || fail "status.php not installed:true ($out)"
  ok "status.php installed:true"

  step "admin login via web (csrf + cookies exactly like a browser)"
  login_test "$(cat /var/lib/nextcloud/admin-password)"
  ok "web login works"
}
