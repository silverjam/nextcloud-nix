#!/usr/bin/env bash
# Upgrade-scenario helpers: version-pin surgery on the container's /test
# copy of the flake, instance seeding, and health assertions.
#
# All scenarios: SAVE_BASE (pin old versions / old nixpkgs rev) → deploy →
# seed → RESTORE_BASE → deploy (the upgrade) → occ upgrade (NC majors) →
# assert the seeded state survived.

SAVE_BASE() {
  cp /test/flake.nix /test/flake.nix.orig
  cp /test/flake.lock /test/flake.lock.orig
}
RESTORE_BASE() {
  cp /test/flake.nix.orig /test/flake.nix
  cp /test/flake.lock.orig /test/flake.lock
}

# version-pin edits (single-line anchors in flake.nix)
PIN_NC()     { sed -i "s|nc = pkgs.nextcloud[0-9]*;.*|nc = pkgs.nextcloud$1;|" /test/flake.nix; }
PIN_PG()     { sed -i "s|pg = pkgs.postgresql_[0-9]*;.*|pg = pkgs.postgresql_$1;|" /test/flake.nix; }
PIN_INPUT()  { sed -i "s|inputs.nixpkgs.url = .*|inputs.nixpkgs.url = \"$1\";|" /test/flake.nix; }

# after PIN_INPUT: re-resolve nixpkgs (fetches the pinned tree once, cached
# in the /nix volume git cache afterwards)
UPDATE_LOCK() { nix flake update nixpkgs >/dev/null; }

# nextcloud/postgresql version as reported by the running instance / binaries
NC_INSTALLED_VERSION() {
  nix run .#occ -- status | grep -oE 'versionstring: [0-9.]+' | head -1 | cut -d' ' -f2
}
PG_BINARY_VERSION() { nix eval --raw .#postgresql.version; }

# seed instance state to protect across an upgrade: a DB marker + a data file
SEED_INSTANCE() {
  MARKER_TS="$(date +%s)"
  echo "$MARKER_TS" > /var/lib/nextcloud/upgrade-marker-ts   # persisted for later phases
  nix run .#occ -- user:setting admin upgradetest marker "$MARKER_TS" >/dev/null
  install -d -o nextcloud -g nextcloud /var/lib/nextcloud/data/admin/files
  printf 'upgrade-drill-%s\n' "$MARKER_TS" \
    > /var/lib/nextcloud/data/admin/files/upgrade-seed.txt
  chown nextcloud:nextcloud /var/lib/nextcloud/data/admin/files/upgrade-seed.txt
}

MARKER_VALUE() {
  local PGBIN
  PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
  runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud \
    -d nextcloud -tAc \
    "SELECT configvalue FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='marker'" \
    | tr -d '[:space:]'
}

# assert the seeded state survived an upgrade + services healthy + optional
# expected app version
ASSERT_HEALTHY() {
  local EXPECTED_NC="$1"
  for u in nextcloud-db nextcloud-fpm nextcloud-caddy; do
    systemctl is-active --quiet "$u" || fail "$u not active ($EXPECTED_NC)"
  done
  local out
  # retry the status assert: the deploy's fpm/config refresh window can
  # briefly serve an empty capture (the prelude's install assert retries too)
  for a in 1 2 3 4 5 6; do
    out="$(curl -s -m 10 "$BASE_URL/status.php" || true)"
    echo "$out" | grep -aq '"installed":true' && break
    sleep 2
  done
  echo "$out" | grep -aq '"installed":true' || fail "status.php not installed ($out)"

  local marker
  marker="$(MARKER_VALUE)"
  if [ "$marker" != "$MARKER_TS" ]; then
    fail "db marker lost across upgrade (expected $MARKER_TS, got '$marker')"
  fi
  test -f /var/lib/nextcloud/data/admin/files/upgrade-seed.txt \
    || fail "seed file lost across upgrade"
  login_test "$(cat /var/lib/nextcloud/admin-password)"
  if [ -n "$EXPECTED_NC" ]; then
    local v
    v="$(NC_INSTALLED_VERSION)"
    case "$v" in "$EXPECTED_NC"*) ;; *) fail "expected NC $EXPECTED_NC*, got $v" ;; esac
    ok "NC $v (marker + seed file + login intact)"
  else
    ok "instance healthy (marker + seed file + login intact)"
  fi
}
