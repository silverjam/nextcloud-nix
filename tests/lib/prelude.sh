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
  nix run .#deploy 2>&1 | tee /tmp/nc-deploy.out
  local deploy_out
  deploy_out="$(cat /tmp/nc-deploy.out)"

  step "units active"
  for u in nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init; do
    systemctl is-active --quiet "$u" || fail "$u not active"
  done
  ok "db/fpm/caddy/init active"

  step "secret files are private"
  local pw
  pw="$(cat /var/lib/nextcloud/admin-password 2>/dev/null || true)"
  [ -n "$pw" ] || fail "admin-password missing"
  if printf '%s' "$deploy_out" | grep -qF "$pw"; then
    fail "deploy output contains the admin password"
  fi
  expect_equal 600 "$(stat -c %a /var/lib/nextcloud/admin-password)" \
    "admin-password is 0600"
  expect_equal 640 "$(stat -c %a /var/lib/nextcloud/config/config.php)" \
    "config.php is 0640"
  expect_equal 640 "$(stat -c %a /var/lib/nextcloud/config/nix.config.php)" \
    "nix.config.php is 0640"
  if grep -aq 'dbpassword' /var/lib/nextcloud/config/nix.config.php; then
    fail "nix.config.php contains dbpassword"
  fi
  ok "deploy hides the admin password; config overlay is secret-free"

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
