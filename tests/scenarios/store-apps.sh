#!/usr/bin/env bash
# Store-apps + memcache + static-serving drill (docker): validates the
# declarative apps through the real deploy (music, memories, files_archive,
# ebookreader all vendored/hash-pinned), the Redis memcache over
# its unix socket, the memcache switch in config.php, and that Caddy serves
# store-installed app assets (the bug that made app UIs silently blank).
install_and_assert
export PATH=/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
PGBIN=$(nix build .#postgresql --no-link --print-out-paths 2>/dev/null | tail -1)
NC=$(nix eval --raw .#packages.x86_64-linux.nextcloud.outPath 2>/dev/null)
PHP=$(nix eval --raw .#packages.x86_64-linux.php.outPath 2>/dev/null)
RCLI=$(nix eval --raw .#packages.x86_64-linux.redis.outPath 2>/dev/null)/bin/redis-cli
FF=$(nix eval --raw .#packages.x86_64-linux.ffmpeg.outPath 2>/dev/null)/bin/ffmpeg
OCC() { sudo -u nextcloud env HOME=/var/lib/nextcloud NEXTCLOUD_CONFIG_DIR=/var/lib/nextcloud/config OC_PASS="${OC_PASS:-}" NC_PASS="${NC_PASS:-}" "$PHP/bin/php" "$NC/occ" "$@"; }
Q() { /usr/bin/sudo -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud -d nextcloud -tAc "$1"; }

step "declarative apps installed + enabled (read-only Nix tree)"
APPS="$(nix build .#nextcloud-apps --no-link --print-out-paths 2>/dev/null | tail -1)"
test -d "$APPS" || fail "nextcloud-apps store tree missing"
for a in music files_archive memories ebookreader; do
  expect_equal 'yes' \
    "$(OCC config:app:get "$a" enabled 2>/dev/null | head -1)" \
    "$a enabled"
  test -f "$APPS/$a/appinfo/info.xml" \
    || fail "$a missing in the read-only Nix app tree"
done
expect_equal "$APPS/files_archive" "$(OCC app:getpath files_archive)" \
  "files_archive runs from the read-only Nix tree"
VERSION=$(grep -aoE '<version>[^<]+' "$APPS/files_archive/appinfo/info.xml" | head -1 | cut -d'>' -f2)
expect_equal '1.3.2' "$VERSION" "files_archive pinned at 1.3.2"
grep -aqF "'appstoreenabled' => false" /var/lib/nextcloud/config/nix.config.php \
  || fail "app store not disabled in nix.config.php"
grep -aqF "/nix-apps" /var/lib/nextcloud/config/nix.config.php \
  || fail "read-only /nix-apps path missing from nix.config.php"
ok "declarative apps materialized in read-only Nix tree"

step "redis memcache over unix socket"
M=/run/redis-nc/redis.sock
[ -S "$M" ] || fail "redis socket missing at $M"
expect_equal 'PONG' \
  "$("$RCLI" -s "$M" ping 2>/dev/null)" \
  "redis PONG over unix socket"
grep -aqF "memcache.distributed' => '\\\\OC\\\\Memcache\\\\Redis'" /var/lib/nextcloud/config/nix.config.php \
  || fail "memcache.distributed not switched to Redis in nix.config.php"
ok "redis alive + memcache.distributed switched"

step "caddy serves Nix app assets"
CSS=$(find "$APPS/files_archive/css" -type f 2>/dev/null | head -1)
test -n "$CSS" || fail "no css assets on disk for files_archive"
URLPATH="/nix-apps${CSS#"$APPS"}"
expect_equal 200 \
  "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:55555$URLPATH")" \
  "Nix app css asset served by caddy"
ok "Nix app assets served"

step "nix.config.php: memories transcode + preview providers"
CFG=/var/lib/nextcloud/config/nix.config.php
grep -aqF "'memories.vod.disable' => false" "$CFG" \
  || fail "memories.vod.disable not set to false"
grep -aqF "'memories.vod.nc_url' => 'http://127.0.0.1:55555'" "$CFG" \
  || fail "memories.vod.nc_url not pointed at the instance"
grep -aqF "$APPS/memories/bin-ext" "$CFG" \
  || fail "memories helper paths not in the read-only Nix tree"
grep -aqF "'OC\\\\Preview\\\\Movie'" "$CFG" \
  || fail "Movie preview provider not enabled"
grep -aqF 'preview_ffmpeg_path' "$CFG" \
  || fail "preview_ffmpeg_path not set"
ok "transcode + preview provider config present"

step "previews: movie provider generates a video thumb"
export OC_PASS=archive-test-password
OCC user:add tuser --password-from-env >/dev/null 2>&1 || true
install -d -o nextcloud -g nextcloud -m 0700 /var/lib/nextcloud/data/tuser/files
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
CFG_MTIME="$(stat -c %Y /var/lib/nextcloud/config/config.php)"
nix run .#deploy >/dev/null 2>&1 || fail "rerun deploy failed"
expect_equal "$CFG_MTIME" "$(stat -c %Y /var/lib/nextcloud/config/config.php)" \
  "rerun deploy left config.php untouched"
for a in music files_archive memories ebookreader; do
  expect_equal 'yes' \
    "$(OCC config:app:get "$a" enabled 2>/dev/null | head -1)" \
    "$a still enabled after rerun"
done
ok "deploy rerun idempotent (apps survive)"
