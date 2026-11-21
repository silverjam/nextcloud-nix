#!/usr/bin/env bash
# Data-mirror drill: deletion-safety (.trash), accidental-delete recovery,
# trash aging, and the flock overlap guard.
install_and_assert

M="/var/backups/nextcloud/data"
SYNC() { nix run .#nc-data-sync -- sync; }

step "create file → sync → mirrored"
F="/var/lib/nextcloud/data/admin/files/mirror-drill.txt"
printf 'mirror-drill\n' > "$F"
chown nextcloud:nextcloud "$F"
SYNC
test -f "$M/admin/files/mirror-drill.txt" || fail "mirror missing the file"
ok "file mirrored"

step "delete + sync → gone from mirror, preserved in .trash"
rm -f "$F"
SYNC
[ ! -f "$M/admin/files/mirror-drill.txt" ] || fail "mirror kept a deleted file"
TR="$(find "$M/.trash" -name 'mirror-drill.txt' 2>/dev/null | head -1)"
[ -n "$TR" ] || fail "deletion was NOT preserved in .trash"
ok "deletion preserved: $TR"

step "accidental-delete recovery: copy back from .trash → sync"
cp "$TR" "$F"
chown nextcloud:nextcloud "$F"
SYNC
test -f "$M/admin/files/mirror-drill.txt" || fail "recovered file not mirrored"
ok "recovery workflow works"

step "trash aging: dirs older than dataSyncTrashDays are pruned"
find "$M/.trash" -mindepth 1 -maxdepth 1 -type d -exec touch -d '31 days ago' {} + 2>/dev/null || true
SYNC
LEFT="$(find "$M/.trash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
expect_equal "0" "$LEFT" "aged trash pruned (30-day window)"

step "flock guard: overlapping sync skips instead of piling up"
flock /var/lib/nextcloud/.data-sync.lock -c 'sleep 5' &
LOCKPID=$!
OUT="$(nix run .#nc-data-sync -- sync 2>&1 || true)"
wait "$LOCKPID"
echo "$OUT" | grep -q "skipped" || fail "expected flock skip, got: $OUT"
ok "overlapping sync skipped"
