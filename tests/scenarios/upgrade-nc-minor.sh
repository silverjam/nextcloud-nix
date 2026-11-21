#!/usr/bin/env bash
# Scenario "upgrade-nc-minor": 34.0.5 → 34.0.6 — a real patch delta obtained
# by pinning nixpkgs at the parent of the bump commit
# ("nextcloud34: 34.0.5 -> 34.0.6", 30ccc78c…). This is exactly what
# `nix flake update` delivers within an NC major.
SAVE_BASE
PIN_INPUT github:NixOS/nixpkgs/ff640e5a344622b344882164d7b76057e4ff8305
UPDATE_LOCK
echo "[scenario] baseline: Nextcloud 34.0.5"
nix run .#deploy
install_and_assert
SEED_INSTANCE
v="$(NC_INSTALLED_VERSION)"
case "$v" in 34.0.5*) ok "baseline installed: NC $v" ;; *) fail "expected NC 34.0.5, got $v" ;; esac

step "upgrade: restore current flake (34.0.6) → deploy → occ upgrade"
RESTORE_BASE
nix run .#deploy
nix run .#occ -- upgrade >/dev/null || fail "occ upgrade failed"
ASSERT_HEALTHY 34.0.6
ok "NC 34.0.5 → 34.0.6 minor upgrade complete"
