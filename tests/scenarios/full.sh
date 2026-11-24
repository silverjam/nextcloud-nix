#!/usr/bin/env bash
# Scenario "full": install + seed file + db/app-state backup + validation +
# state-restore roundtrip.

install_and_assert

step "seed a file via the data dir + files:scan"
install -d -o nextcloud -g nextcloud /var/lib/nextcloud/data/admin/files
printf 'nc-test-payload-%s\n' "$(date +%s)" \
  > /var/lib/nextcloud/data/admin/files/nc-test-seed.txt
chown nextcloud:nextcloud /var/lib/nextcloud/data/admin/files/nc-test-seed.txt
nix run .#occ -- files:scan admin | grep -qE 'Added|new files|Found' || true
ok "seed file present"

step "app-state backup (db dump + config, no data/)"
nix run .#nc-backup -- incremental
nix run .#nc-backup -- validate
nix run .#nc-backup -- validate-deep
ok "backup validated (TOC + deep restore)"

step "break config.php, then restore from archive"
rm -f /var/lib/nextcloud/config/config.php
FORCE=1 nix run .#nc-restore -- latest
systemctl is-active --quiet nextcloud-fpm || fail "fpm not active after restore"
test -f /var/lib/nextcloud/config/config.php || fail "config.php not restored"
test -f /var/lib/nextcloud/data/admin/files/nc-test-seed.txt \
  || fail "seed vanished after state-restore"
ok "state restore roundtrip (config.db ↔ untouched data/)"

step "post-restore login + files:scan"
login_test "$(cat /var/lib/nextcloud/admin-password)"
nix run .#occ -- files:scan admin >/dev/null
ok "post-restore instance healthy"
