#!/usr/bin/env bash
# Scenario "upgrade-nc-major": NC 33 → 34, the supported one-major step within
# the pinned nixpkgs tree. Exercises the documented flow:
#   maintenance:mode on → deploy → occ upgrade → mode off → assert state.
SAVE_BASE
PIN_NC 33
echo "[scenario] baseline: Nextcloud 33"
nix run .#deploy
install_and_assert
SEED_INSTANCE
v="$(NC_INSTALLED_VERSION)"
case "$v" in 33.0*) ok "baseline installed: NC $v" ;; *) fail "expected NC 33.0.x, got $v" ;; esac

step "upgrade: restore current flake (NC 34) → deploy → occ upgrade"
RESTORE_BASE
nix run .#deploy
nix run .#occ -- maintenance:mode --on >/dev/null
nix run .#occ -- upgrade >/dev/null || fail "occ upgrade failed"
nix run .#occ -- maintenance:mode --off >/dev/null
ASSERT_HEALTHY 34
ok "NC 33 → 34 major upgrade complete"
