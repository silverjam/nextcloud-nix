#!/usr/bin/env bash
# Scenario "reset": wipe everything, prove determinism, re-assert.

install_and_assert

step "reset (interactive confirm satisfied via stdin)"
printf 'RESET\n' | nix run .#just -- -f /test/justfile -d /test reset

step "fresh install asserts again"
install_and_assert
ok "reset → identical healthy install"
