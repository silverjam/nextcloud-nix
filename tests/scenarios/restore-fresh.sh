#!/usr/bin/env bash
# Disaster-recovery drill: backup → FULL reset (wipes instance, keeps repo +
# passfile) → restore latest onto the fresh host → prove the pre-reset state
# came back. This is the restore-onto-blank-host path.
install_and_assert

PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
PSQL() { runuser -u nextcloud -- "$PGBIN/bin/psql" \
  -h /run/nextcloud-db -U nextcloud -d nextcloud "$@"; }

OLD_PW="$(cat /var/lib/nextcloud/admin-password)"
TS="$(date +%s)"
nix run .#occ -- user:setting admin test restore_fresh "$TS" >/dev/null

step "take the backup"
nix run .#nc-backup -- incremental

step "reset (interactive confirm via stdin; repo + .restic-pass survive)"
printf 'RESET\n' | nix run .#just -- -f /test/justfile -d /test reset

step "state is fresh: instance is NOT the backup"
NEW_PW="$(cat /var/lib/nextcloud/admin-password)"
[ "$NEW_PW" != "$OLD_PW" ] || fail "admin password file did not rotate after reset"
C="$(PSQL -tAc "SELECT count(*) FROM oc_preferences WHERE appid='test'")"
expect_equal "0" "$C" "fresh install has no drill markers"

step "restore latest onto the fresh host"
FORCE=1 nix run .#nc-restore -- latest

step "pre-reset state is back"
RESTORED_PW="$(cat /var/lib/nextcloud/admin-password)"
expect_equal "$OLD_PW" "$RESTORED_PW" "admin password file from archive"
C="$(PSQL -tAc "SELECT count(*) FROM oc_preferences WHERE appid='test' AND configvalue='$TS'")"
expect_equal "1" "$C" "db marker restored"
login_test "$OLD_PW"
nix run .#occ -- status | grep -q 'installed: true' || fail "not installed after restore"
ok "restore-onto-fresh-host works end to end"
