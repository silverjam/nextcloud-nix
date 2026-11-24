#!/usr/bin/env bash
# Streamed into the VM after a reboot cycle (VM harness only).
# Asserts everything that must survive a power cycle: unit enablement,
# persistent timers, instance state, working login.
step "post-reboot: units active"
for u in nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init; do
  systemctl is-active --quiet "$u" || fail "$u not active after reboot"
done
ok "db/fpm/caddy/init active after reboot"

step "timers registered after reboot (Persistent=true)"
for t in nextcloud-cron.timer nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer; do
  systemctl list-timers "$t" --no-pager | grep -q "$t" || fail "$t missing after reboot"
done
ok "all four timers registered"

step "instance state persisted"
test -f /var/lib/nextcloud/config/config.php || fail "config.php gone"
test -f /var/lib/nextcloud/admin-password || fail "admin-password gone"
out="$(curl -s -m 10 "$BASE_URL/status.php" || true)"
echo "$out" | grep -q '"installed":true' || fail "status.php: $out"
ok "status.php installed:true"

step "admin login after reboot"
login_test "$(cat /var/lib/nextcloud/admin-password)"
ok "login works after reboot"
