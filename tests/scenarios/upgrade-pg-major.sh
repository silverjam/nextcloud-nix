#!/usr/bin/env bash
# Scenario "upgrade-pg-major": PostgreSQL 17 → 18 — a real major delta. A 17
# data dir cannot be read by an 18 binary, so this exercises EXACTLY the
# documented procedure from the README: full backup (pg_dump is the migration
# vehicle) → rebuild with the new major → fresh cluster → restore from the
# full archive → assert everything came back.
SAVE_BASE
echo "[scenario] baseline: PostgreSQL 17 with seeded state"
nix run .#deploy
install_and_assert
SEED_INSTANCE
nix run .#nc-backup -- full
nix run .#nc-backup -- validate-deep
ok "full archive taken (migration vehicle)"

step "upgrade: PIN_PG 18 → deploy (db unit is EXPECTED to fail on the 17 data dir)"
PIN_PG 18
nix run .#deploy || true
systemctl is-failed --quiet nextcloud-db || {
  systemctl is-active --quiet nextcloud-db && fail "db unexpectedly active on pg18 binary with 17 data dir"
}

step "documented recovery: fresh 18 cluster → restore from the full archive"
systemctl stop nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-cron.timer \
  nextcloud-snapshot.timer 2>/dev/null || true
rm -rf /var/lib/nextcloud-db
# NOTE: this deploy aborts at init — mid-recovery state (config.php exists,
# database empty) is not installable; the restore below heals it
nix run .#deploy || echo "  (deploy aborted mid-recovery — expected; restore heals this)"
FORCE=1 nix run .#nc-restore -- latest
nix run .#deploy

step "post-migration asserts under PostgreSQL 18"
v="$(PG_BINARY_VERSION)"
case "$v" in 18.*) ok "now on PostgreSQL $v" ;; *) fail "expected pg 18, got $v" ;; esac
ASSERT_HEALTHY ""
nix run .#nc-backup -- validate-deep
RESTORE_BASE
ok "PG 17 → 18 major upgrade complete (dump/restore path)"
