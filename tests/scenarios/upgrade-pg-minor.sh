#!/usr/bin/env bash
# Scenario "upgrade-pg-minor": PostgreSQL 17.11 → 17.12 — a real minor delta
# obtained by pinning nixpkgs at the parent of the bump commit
# ("postgresql_17: 17.11 -> 17.12", a9e16966…). Minors upgrade in place: the
# data dir survives a binary swap within the same major.
SAVE_BASE
PIN_INPUT github:NixOS/nixpkgs/3f946f4023237af0c3a9bb773918340b4aaf8628
UPDATE_LOCK
echo "[scenario] baseline: PostgreSQL 17.11"
nix run .#deploy
install_and_assert
SEED_INSTANCE
v="$(PG_BINARY_VERSION)"
case "$v" in 17.11*) ok "baseline installed: PostgreSQL $v" ;; *) fail "expected pg 17.11, got $v" ;; esac
NCV="$(NC_INSTALLED_VERSION)"
case "$NCV" in 34.0.5*) ok "baseline app: NC $NCV" ;; *) fail "expected NC 34.0.5, got $NCV" ;; esac

step "upgrade: restore current flake → deploy (pg 17.11→17.12 AND nc 34.0.5→34.0.6 move together, exactly like a real `nix flake update`) → occ upgrade"
RESTORE_BASE
nix run .#deploy
nix run .#occ -- upgrade >/dev/null || fail "occ upgrade failed"
v2="$(PG_BINARY_VERSION)"
case "$v2" in 17.12*) ok "now on PostgreSQL $v2" ;; *) fail "expected pg 17.12, got $v2" ;; esac
ASSERT_HEALTHY 34.0.6
nix run .#nc-backup -- incremental     # first dump UNDER the new pg binary
nix run .#nc-backup -- validate-deep
ok "pg 17.11→17.12 (+nc patch bump) upgrade complete (data dir survived)"
