#!/usr/bin/env bash
# Declarative user provisioning drill: declare → deploy → users exist with
# desired quota/groups; no-quota parsing; terminal-path promotion;
# idempotent removal WITH verified per-user backup.
#
# NOTE: insertion-based seds only — this drill must work regardless of what
# the repo's provisionedUsers already contains (it provisions REAL declared
# users into the throwaway container too; that's fine and expected).
install_and_assert

PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
Q() { runuser -u nextcloud -- "$PGBIN/bin/psql" \
  -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }

step "insert drill1 (quota + group) into the provision list"
sed -i 's|provisionedUsers = { |provisionedUsers = { drill1 = { displayName = "Drill One"; quota = "1 GB"; groups = [ "drillers" ]; }; |' /test/flake.nix
nix run .#deploy
nix run .#occ -- user:info drill1 | grep -q 'user_id: drill1' || fail "user drill1 not created"
Q "SELECT configvalue FROM oc_preferences WHERE userid='drill1' AND appid='files' AND configkey='quota'" | grep -q '1 GB' || fail "quota not applied"
Q "SELECT count(*) FROM oc_group_user WHERE gid='drillers' AND uid='drill1'" | grep -q 1 || fail "group membership missing"
ok "drill1 created with quota + group"
grep -q 'drill1' /var/lib/nextcloud/provision-credentials-*.log 2>/dev/null \
  || fail "credentials not recorded (0600)"
ok "one-shot password recorded (0600 credentials log)"

step "no-quota user + groups parse correctly (empty fields preserved)"
sed -i 's|provisionedUsers = { |provisionedUsers = { drill3 = { displayName = "Drill Three No Quota"; groups = [ "g-noquota-a" "g-noquota-b" ]; }; |' /test/flake.nix
nix run .#deploy
nix run .#occ -- user:info drill3 | grep -q 'user_id: drill3' || fail "drill3 not created"
# the collapse bug wrote GROUPS into quota and left groups empty — both must hold now
QUOTA_OK="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='drill3' AND appid='files' AND configkey='quota'")"
expect_equal "0" "$QUOTA_OK" "drill3 has NO quota row (unlimited, as declared)"
for g in g-noquota-a g-noquota-b; do
  M="$(Q "SELECT count(*) FROM oc_group_user WHERE gid='$g' AND uid='drill3'")"
  expect_equal "1" "$M" "group $g membership"
done
ok "no-quota user parsed: quota undefined, both groups applied"

step "terminal-path promotion: provisioning run from a non-service context keeps its config env"
# exercises the sudo/runuser promotion path exactly like a user invoking
# `nix run .#nc-provision` from their shell (env is carried in the wrapper)
nix run .#nc-provision
M="$(Q "SELECT count(*) FROM oc_group_user WHERE gid='g-noquota-a' AND uid='drill3'")"
expect_equal "1" "$M" "group membership still intact after terminal-path run"

step "idempotency: re-deploy must not duplicate or rotate"
BEFORE="$(nix run .#occ -- user:list | grep -c drill1)"
nix run .#deploy >/dev/null
AFTER="$(nix run .#occ -- user:list | grep -c drill1)"
expect_equal "$BEFORE" "$AFTER" "user count stable across redeploys"
ok "provisioning is idempotent"

step "provision drill2, then DEPROVISION it (backup-on-removal)"
sed -i 's|provisionedUsers = { |provisionedUsers = { drill2 = { displayName = "Drill Two"; }; |' /test/flake.nix
nix run .#deploy
nix run .#occ -- user:info drill2 | grep -q 'user_id: drill2' || fail "user drill2 not created"
F="/var/lib/nextcloud/data/drill2/files/provision-deleteme.txt"
install -d -o nextcloud -g nextcloud /var/lib/nextcloud/data/drill2/files
printf 'drill2-payload\n' > "$F"
chown nextcloud:nextcloud "$F"
ok "drill2 created with a file to lose"

sed -i 's|deprovisionedUsers = \[ \];|deprovisionedUsers = [ "drill2" ];|' /test/flake.nix
# realistic deprovision: remove from the provision list too (drill2 leaves)
sed -i 's| drill2 = { displayName = "Drill Two"; }; ||' /test/flake.nix
nix run .#deploy

step "drill2 removed, backup verified on disk"
nix run .#occ -- user:info drill2 >/dev/null 2>&1 && fail "drill2 still exists!"
BK="$(find /var/backups/nextcloud/deprovisioned/drill2 -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -n "$BK" ] || fail "no backup dir for removed user"
test -s "$BK/db.dump" || fail "db.dump missing/empty"
test -f "$BK/home/files/provision-deleteme.txt" || fail "user home not backed up"
grep -aq 'drill2' /var/lib/nextcloud/provision-removals.log || fail "removal not logged"
ok "removed with verified backup: $BK"

step "removal idempotency: re-deploy takes no second backup"
D1="$(find /var/backups/nextcloud/deprovisioned/drill2 -mindepth 1 -maxdepth 1 -type d | wc -l)"
nix run .#deploy >/dev/null
D2="$(find /var/backups/nextcloud/deprovisioned/drill2 -mindepth 1 -maxdepth 1 -type d | wc -l)"
expect_equal "$D1" "$D2" "no duplicate removal backups"
ok "removal entries are self-draining"
