#!/usr/bin/env bash
# Deep drill: proves the DATABASE content round-trips through backup→restore,
# not just that the commands exit 0. Also asserts maintenance-mode cleanliness,
# scratch-db hygiene, and restic repo integrity.
install_and_assert

PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
PSQL() { runuser -u nextcloud -- "$PGBIN/bin/psql" \
  -h /run/nextcloud-db -U nextcloud -d nextcloud "$@"; }

step "plant a marker in the DATABASE, then snapshot"
TS="$(date +%s)"
nix run .#occ -- user:setting admin test backup_marker "$TS" >/dev/null
nix run .#nc-backup -- incremental
nix run .#nc-backup -- validate-deep
ok "snapshot saved + deep-validated"

step "maintenance mode is OFF after backup (trap guarantee)"
M="$(nix run .#occ -- config:system:get maintenance | tr -d '[:space:]')"
expect_equal "false" "$M" "maintenance mode clean"

step "validate-deep left no scratch databases behind"
C="$(PSQL -tAc "SELECT count(*) FROM pg_database WHERE datname LIKE 'nc_verify_%'")"
expect_equal "0" "$C" "scratch db hygiene"

step "mutate the marker, restore latest, assert DB rollback"
nix run .#occ -- user:setting admin test backup_marker "changed-after-snapshot" >/dev/null
FORCE=1 nix run .#nc-restore -- latest
V="$(PSQL -tAc "SELECT configvalue FROM oc_preferences WHERE uid='admin' AND appid='test' AND configkey='backup_marker'" | tr -d '[:space:]')"
expect_equal "$TS" "$V" "db marker rolled back by restore"

step "post-restore integrity"
nix run .#nc-backup -- check
login_test "$(cat /var/lib/nextcloud/admin-password)"
ok "repo integrity + login after restore"
