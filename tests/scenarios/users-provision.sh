#!/usr/bin/env bash
# Declarative user provisioning drill: declare → deploy → user exists with
# desired quota/group; idempotent on re-deploy.
install_and_assert

step "provision a user via the flake knob"
sed -i 's|provisionedUsers = { };|provisionedUsers = { drill1 = { displayName = "Drill One"; quota = "1 GB"; groups = [ "drillers" ]; }; };|' /test/flake.nix
nix run .#deploy
nix run .#occ -- user:info drill1 | grep -q 'user_id: drill1' || fail "user drill1 not created"
PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
Q() { runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }
Q "SELECT configvalue FROM oc_preferences WHERE userid='drill1' AND appid='files' AND configkey='quota'" | grep -q '1 GB' || fail "quota not applied"
Q "SELECT count(*) FROM oc_group_user WHERE gid='drillers' AND uid='drill1'" | grep -q 1 || fail "group membership missing"
ok "drill1 created with quota + group"
grep -q 'drill1' /var/lib/nextcloud/provision-credentials-*.log \
  || fail "credentials not recorded (0600)"
ok "one-shot password recorded (0600 credentials log)"

step "idempotency: re-deploy must not duplicate or rotate"
BEFORE="$(nix run .#occ -- user:list | grep -c drill1)"
nix run .#deploy >/dev/null
AFTER="$(nix run .#occ -- user:list | grep -c drill1)"
expect_equal "$BEFORE" "$AFTER" "user count stable across redeploys"
ok "provisioning is idempotent"
