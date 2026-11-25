#!/usr/bin/env bash
# Scenario "upgrade-nc-major": NC 33 → 34, the supported one-major step within
# the pinned nixpkgs tree. Exercises the documented flow:
#   maintenance:mode on → deploy → occ upgrade → mode off → assert state.
SAVE_BASE
PIN_NC 33
# memories 11.1.4 declares Nextcloud 34-35, so the NC33 baseline must not
# enable it or the deploy's fail-closed app check stops before the upgrade.
# The restored flake enables all four apps on NC34.
sed -i 's|"memories" ||' /test/flake.nix
grep -q '"memories"' /test/flake.nix \
  && { echo "[scenario] failed to drop memories from the baseline app list" >&2; exit 1; }
echo "[scenario] baseline: Nextcloud 33"
nix run .#deploy
install_and_assert
SEED_INSTANCE
v="$(NC_INSTALLED_VERSION)"
case "$v" in 33.0*) ok "baseline installed: NC $v" ;; *) fail "expected NC 33.0.x, got $v" ;; esac

step "upgrade: restore current flake (NC 34) → deploy → occ upgrade"
# NOTE: during a MAJOR swap the init unit may fail mid-deploy: it runs
# db-occ commands (db:add-missing-indices) that are blocked while
# needsDbUpgrade — the upgrade itself clears it. Two-phase deploy.
RESTORE_BASE
nix run .#deploy || echo "  (deploy aborted at init — expected during a major swap)"
nix run .#apply-config          # de-stale apps_paths BEFORE any occ boot
nix run .#occ -- upgrade >/tmp/nc-upgrade-output.log 2>&1 || {
  echo "occ upgrade failed — output:"
  sed 's/^/  | /' /tmp/nc-upgrade-output.log | tail -n 30
  exit 1
}
nix run .#occ -- maintenance:mode --off >/dev/null
nix run .#deploy >/dev/null          # clean pass now that the db is at 34
ASSERT_HEALTHY 34
ok "NC 33 → 34 major upgrade complete"
