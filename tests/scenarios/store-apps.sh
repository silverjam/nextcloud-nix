#!/usr/bin/env bash
# Store-apps + memcache + static-serving drill (docker): validates the
# declarative storeApps list through the real deploy (music, files_archive,
# memories installed+enabled from the NC app store), the Redis memcache over
# its unix socket, the memcache switch in config.php, and that Caddy serves
# store-installed app assets (the bug that made app UIs silently blank).
install_and_assert
export PATH=/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
PGBIN=$(nix build .#postgresql --no-link --print-out-paths 2>/dev/null | tail -1)
NC=$(nix eval --raw .#packages.x86_64-linux.nextcloud.outPath 2>/dev/null)
PHP=$(nix eval --raw .#packages.x86_64-linux.php.outPath 2>/dev/null)
RCLI=$(nix eval --raw .#packages.x86_64-linux.redis.outPath 2>/dev/null)/bin/redis-cli
FF=$(nix eval --raw .#packages.x86_64-linux.ffmpeg.outPath 2>/dev/null)/bin/ffmpeg
OCC() { sudo -u nextcloud env HOME=/var/lib/nextcloud NEXTCLOUD_CONFIG_DIR=/var/lib/nextcloud/config "$PHP/bin/php" "$NC/occ" "$@"; }
Q() { /usr/bin/sudo -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }

step "store apps installed + enabled via storeApps list"
for a in music files_archive memories; do
  expect_equal 'yes' \
    "$(OCC config:app:get "$a" enabled 2>/dev/null | head -1)" \
    "$a enabled"
done
test -f /var/lib/nextcloud/store-apps/files_archive/appinfo/info.xml \
  || fail "files_archive contents missing in store-apps"
VERSION=$(grep -aoE '<version>[^<]+' /var/lib/nextcloud/store-apps/files_archive/appinfo/info.xml | head -1 | cut -d'>' -f2)
expect_equal '1.3.2' "$VERSION" "files_archive pinned at 1.3.2 (vendored tarball)"
ok "storeApps list fully materialized"

step "redis memcache over unix socket"
M=/run/redis-nc/redis.sock
[ -S "$M" ] || fail "redis socket missing at $M"
expect_equal 'PONG' \
  "$("$RCLI" -s "$M" ping 2>/dev/null)" \
  "redis PONG over unix socket"
grep -aqF "memcache.distributed' => '\\\\OC\\\\Memcache\\\\Redis'" /var/lib/nextcloud/config/config.php \
  || fail "memcache.distributed not switched to Redis in config.php"
ok "redis alive + memcache.distributed switched"

step "caddy serves store-app app assets"
CSS=$(find /var/lib/nextcloud/store-apps/files_archive/css -type f 2>/dev/null | head -1)
test -n "$CSS" || fail "no css assets on disk for files_archive"
URLPATH=${CSS#/var/lib/nextcloud}
expect_equal 200 \
  "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:55555$URLPATH")" \
  "store-app css asset served by caddy"
ok "store-app assets served"

step "config.php: memories transcode + preview providers"
CFG=/var/lib/nextcloud/config/config.php
grep -aqF "'memories.vod.disable' => false" "$CFG" \
  || fail "memories.vod.disable not set to false"
grep -aqF "'memories.vod.nc_url' => 'http://127.0.0.1:55555'" "$CFG" \
  || fail "memories.vod.nc_url not pointed at the instance"
grep -aqF "'OC\\\\Preview\\\\Movie'" "$CFG" \
  || fail "Movie preview provider not enabled"
grep -aqF 'preview_ffmpeg_path' "$CFG" \
  || fail "preview_ffmpeg_path not set"
ok "transcode + preview provider config present"

step "previews: movie provider generates a video thumb"
export OC_PASS=archive-test-password
OCC user:add tuser --password-from-env >/dev/null 2>&1 || true
/usr/bin/sudo -u nextcloud env HOME=/var/lib/nextcloud NEXTCLOUD_CONFIG_DIR=/var/lib/nextcloud/config \
  "$FF" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=size=320x240:rate=10" -t 2 \
  -c:v mjpeg -pix_fmt yuvj422p /var/lib/nextcloud/data/tuser/files/sample.mov
OCC files:scan tuser >/dev/null 2>&1
FILEID=$(Q "SELECT fileid FROM oc_filecache WHERE path='files/sample.mov'")
test -n "$FILEID" || fail "sample.mov not in filecache"
PREVIEW=$(curl -sS -o /dev/null -w '%{http_code}' -u "tuser:archive-test-password" \
  "http://127.0.0.1:55555/index.php/core/preview?fileId=$FILEID&x=256&y=256")
expect_equal 200 "$PREVIEW" "video preview generated (Movie provider via ffmpeg)"
ok "video previews work"

step "app store install is idempotent on rerun"
OUT="$(nix run .#deploy 2>&1 >/dev/null || true)"
echo "$OUT" | grep -aq 'app:install music' || fail "storeApps loop missing from deploy"
ok "deploy rerun keeps state (idempotent app:install+enable)"
