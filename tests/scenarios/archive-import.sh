#!/usr/bin/env bash
# NC archive-import drill (docker): plants a small source tree whose oldest
# file is dated 2007, then runs the REAL nc-import-archive recipe and asserts
# the whole chain: migration gate order, owner provisioning gate, resumable
# copy, computed folder name, filecache rows, the parents group share
# (visibility + delete-through-UI landing in trash), the retention config
# keys, and that zfs-disaster-mirror-remove stays locked until import-complete
# AND only runs with CONFIRM=disaster.
install_and_assert

MS=/var/backups/nextcloud/migration-state
nix run .#deploy >/dev/null 2>&1 || true
systemctl start nextcloud-provision.service 2>/dev/null || true

step "gate: mirror-remove locked without import-complete"
mkdir -p "$MS"
touch "$MS/migration-complete"
ERR="$(CONFIRM=disaster nix run .#zfs-disaster-mirror-remove 2>&1 >/dev/null || true)"
echo "$ERR" | grep -aq 'import-complete' \
  || fail "mirror-remove did not require import-complete (got: $ERR)"
ok "mirror-remove requires import-complete stamp"

step "import: owner user + planted source"
nix run .#occ -- user:info archive >/dev/null 2>&1 || {
  OC_PASS=import-test-password nix run .#occ -- user:add archive --password-from-env >/dev/null
}
nix run .#occ -- group:adduser parents archive >/dev/null 2>&1 || true
SRC=/var/archives-src
rm -rf "$SRC"
mkdir -p "$SRC/2007/dir" "$SRC/2024/dir"
printf 'old payload\n' > "$SRC/2007/oldest.txt"
touch -d '2007-01-05 03:00' "$SRC/2007/oldest.txt"
printf 'newer\n' > "$SRC/2024/newer.txt"
printf 'top\n' > "$SRC/top.txt"
mkdir -p "$SRC/videos"
export PATH=/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
FF=$(nix build --no-link --print-out-paths .#ffmpeg 2>/dev/null | tail -1)/bin/ffmpeg
"$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=320x240:rate=10" -t 2 -c:v mjpeg -pix_fmt yuvj422p "$SRC/videos/legacy-cam.mov"
sed -i 's|archiveSource = ".*";|archiveSource = "/var/archives-src";|' /test/flake.nix

step "import: run the real recipe"
nix run .#nc-import-archive

expect_equal 1 \
  "$(test -f '/var/lib/nextcloud/data/archive/files/Archive 2007-2026/2007/oldest.txt' && echo 1)" \
  "folder named from the oldest file (Archive 2007-2026)"
[ "$(find '/var/lib/nextcloud/data/archive/files/Archive 2007-2026' -type f | wc -l)" -eq 3 ] \
  || fail "expected 3 imported files"
grep -aF "'trashbin_retention_obligation' => 'disabled'" /var/lib/nextcloud/config/config.php >/dev/null \
  || fail "trashbin retention not disabled in config.php"
grep -aF "'versions_retention_obligation' => 'disabled'" /var/lib/nextcloud/config/config.php >/dev/null \
  || fail "versions retention not disabled in config.php"
ok "copy, computed name, and retention config verified"

step "import: filecache rows"
PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
Q() { runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }
expect_equal 3 \
  "$(Q "SELECT count(*) FROM oc_filecache WHERE name IN ('oldest.txt','newer.txt','top.txt')")" \
  "filecache picked up the imported files"

step "import: group share visible to a member"
PW="$(grep -ah '^uid=jason password=' /var/lib/nextcloud/provision-credentials-*.log 2>/dev/null \
  | sed -E 's/^[^ ]+ password=([^ ]+).*/\1/' | tail -1)"
[ -n "$PW" ] || fail "jason credentials not found"
expect_equal 1 \
  "$(Q "SELECT count(*) FROM oc_share WHERE share_type=3 AND share_with='parents' AND permissions=15")" \
  "group share exists with permissions 15"
curl -sS -u "jason:$PW" -X PROPFIND -H 'Depth: 1' "$BASE_URL/remote.php/dav/files/jason/" \
  | grep -aq 'Archive 2007-2026' \
  || fail "jason does not see the shared folder"
ok "share visible to the parents group"

step "retention: a member's delete lands in trash and stays"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' -u "jason:$PW" \
  -X DELETE "$BASE_URL/remote.php/dav/files/jason/Archive%202007-2026/top.txt")"
expect_equal 204 "$CODE" "DELETE through the share"
expect_equal 1 \
  "$(Q "SELECT count(*) FROM oc_files_trash")" \
  "deleted file sits in trash (retention disabled, nothing auto-expired)"
ok "delete-through-UI kept in trash"

step "import: rerun is idempotent"
OUT="$(nix run .#nc-import-archive 2>&1)"
echo "$OUT" | grep -aq 'already imported' || fail "rerun did not skip the copy pass"
echo "$OUT" | grep -aq 'share already present' || fail "rerun did not detect the share"
ok "rerun skips copy + share"

step "transcode: undecodable mjpeg gets an h264 sibling"
NC=$(nix eval --raw .#packages.x86_64-linux.nextcloud.outPath 2>/dev/null)
PHP=$(nix eval --raw .#packages.x86_64-linux.php.outPath 2>/dev/null)
OCC2() { sudo -u nextcloud env HOME=/var/lib/nextcloud NEXTCLOUD_CONFIG_DIR=/var/lib/nextcloud/config "$PHP/bin/php" "$NC/occ" "$@"; }
nix run .#nc-transcode-unplayable >/dev/null
CONV="/var/lib/nextcloud/data/archive/files/Archive 2007-2026/videos/legacy-cam.mp4"
test -f "$CONV" || fail "transcoded sibling mp4 missing"
C=$(ffprobe -v quiet -show_entries stream=codec_name,codec_type -of csv=p=0 "$CONV" 2>/dev/null | head -1)
case "$C" in *"h264,video"*) ;; *) fail "converted file is not h264 (got: $C)";; esac
[ -f "$SRC/videos/legacy-cam.mov" ] || fail "original mov was removed"
ok "transcode made an h264 sibling, original preserved"
step "gate: mirror-remove executes only with import-complete + CONFIRM"
mkdir -p /var/backups/disaster-mirror-sdc1
printf x > /var/backups/disaster-mirror-sdc1/f.txt
ERR="$(nix run .#zfs-disaster-mirror-remove 2>&1 >/dev/null || true)"
echo "$ERR" | grep -aq 'CONFIRM' || fail "mirror-remove ran without CONFIRM"
CONFIRM=disaster nix run .#zfs-disaster-mirror-remove >/dev/null
[ ! -e /var/backups/disaster-mirror-sdc1 ] || fail "mirror still present after removal"
ok "mirror-remove unlock order verified"
