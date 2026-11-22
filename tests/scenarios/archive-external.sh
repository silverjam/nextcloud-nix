#!/usr/bin/env bash
# Interim archive-external drill (docker): the archive dataset binds into the
# datadir via the systemd mount unit (zero copy), nc-archive-share scans and
# group-shares it, and a member's delete lands in trash with the data intact.
# Asserts the bind unit wiring, the retention config, share visibility, and
# idempotent reruns.
install_and_assert
systemctl start nextcloud-provision.service 2>/dev/null || true

step "gate: share recipe refuses without the bind"
MS=/var/backups/nextcloud/migration-state
mkdir -p "$MS"
touch "$MS/migration-complete"
ERR="$(nix run .#nc-archive-share 2>&1 >/dev/null || true)"
echo "$ERR" | grep -aq 'bind-mounted' || fail "share recipe did not require the bind (got: $ERR)"
ok "share recipe requires the bind mount"

step "plant source + deploy (mount unit comes up)"
SRC=/var/ext-archive
rm -rf "$SRC"
mkdir -p "$SRC/family"
printf 'family payload\n' > "$SRC/family/file.txt"
touch -d '2012-06-27 12:00' "$SRC/family/file.txt"
sed -i 's|archiveSource = ".*";|archiveSource = "/var/ext-archive";|' /test/flake.nix
nix run .#deploy >/dev/null 2>&1
systemctl start nextcloud-provision.service 2>/dev/null || true
nix run .#occ -- user:info archive >/dev/null 2>&1 || {
  OC_PASS=external-test-password nix run .#occ -- user:add archive --password-from-env >/dev/null
}
nix run .#occ -- group:adduser parents archive >/dev/null 2>&1 || true
findmnt -no SOURCE /var/lib/nextcloud/data/archive/files/Archive | grep -aq /var/ext-archive \
  || fail "bind unit did not mount the planted source"
ok "bind unit mounted /var/ext-archive into the datadir"

step "share: scan + group share"
nix run .#nc-archive-share
PW="$(grep -ah '^uid=jason password=' /var/lib/nextcloud/provision-credentials-*.log 2>/dev/null \
  | sed -E 's/^[^ ]+ password=([^ ]+).*/\1/' | tail -1)"
[ -n "$PW" ] || fail "jason credentials not found"
grep -aF "'trashbin_retention_obligation' => 'disabled'" /var/lib/nextcloud/config/config.php >/dev/null \
  || fail "trash retention not disabled in config.php"
grep -aF "'versions_retention_obligation' => 'disabled'" /var/lib/nextcloud/config/config.php >/dev/null \
  || fail "versions retention not disabled in config.php"
ok "retention config present in config.php"

step "share: member visibility + delete-through-UI"
PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
Q() { runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }
expect_equal 1 \
  "$(Q "SELECT count(*) FROM oc_share WHERE share_type=0 AND share_with='jason' AND permissions=15")" \
  "member share for jason exists with permissions 15"
curl -sS -u "jason:$PW" -X PROPFIND -H 'Depth: 1' "$BASE_URL/remote.php/dav/files/jason/" \
  | grep -aq 'Archive' || fail "jason does not see the bound archive folder"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -u "jason:$PW" \
  -X DELETE "$BASE_URL/remote.php/dav/files/jason/Archive/family/file.txt")"
expect_equal 204 "$CODE" "delete through the share"
[ "$(ls "$SRC/family" 2>/dev/null | wc -l)" -eq 0 ] \
  || fail "file still in the archive dataset after trash move"
expect_equal 1 "$(Q "SELECT count(*) FROM oc_files_trash")" \
  "deleted file sits in trash (nothing auto-expired)"
curl -sS -u "jason:$PW" -X PROPFIND -H 'Depth: 1' "$BASE_URL/remote.php/dav/trashbin/jason/trash/" \
  | grep -aq 'file.txt' || fail "file not visible in trash via DAV"
ok "delete-through-UI lands in trash, dataset copy preserved"

step "share: rerun is idempotent"
OUT="$(nix run .#nc-archive-share 2>&1)"
echo "$OUT" | grep -aq 'member shares already present' || fail "rerun did not detect the shares"
ok "rerun idempotent"
