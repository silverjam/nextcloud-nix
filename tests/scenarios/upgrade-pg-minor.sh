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

step "upgrade: restore current flake (17.12) → deploy (in-place restart)"
RESTORE_BASE
nix run .#deploy
v2="$(PG_BINARY_VERSION)"
case "$v2" in 17.12*) ok "now on PostgreSQL $v2" ;; *) fail "expected pg 17.12, got $v2" ;; esac
ASSERT_HEALTHY ""
nix run .#nc-backup -- validate-deep
ok "PG 17.11 → 17.12 minor upgrade complete (data dir survived)"
