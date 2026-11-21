#!/usr/bin/env bash
# Retention drill: feed the policy a pile of backdated snapshots, prove
# forget --prune actually prunes (and that the live snapshot survives).
install_and_assert

RESTIC_OUT="$(nix build nixpkgs#restic --no-link --print-out-paths | tail -1)"
RT() {
  runuser -u nextcloud -- env \
    HOME=/var/lib/nextcloud XDG_CACHE_HOME=/var/lib/nextcloud/cache \
    RESTIC_REPOSITORY=/var/backups/nextcloud/repo \
    RESTIC_PASSWORD_FILE=/var/backups/nextcloud/.restic-pass \
    "$RESTIC_OUT/bin/restic" "$@"
}
COUNT() { RT snapshots --compact | grep -cE '^[0-9a-f]{8}' || echo 0; }

step "one real snapshot (this one must survive pruning)"
OUT="$(nix run .#nc-backup -- incremental)"
RID="$(printf '%s' "$OUT" | grep -oE 'snapshot [0-9a-f]{8}' | awk '{print $2}')"
[ -n "$RID" ] || fail "could not read snapshot id from backup output"

step "synthesize 100 snapshots inside ~2 hours (saturate the hourly buckets)"
for i in $(seq 0 99); do
  RT backup --time "$(date -d "-$((i + 3)) minutes" '+%Y-%m-%d %H:%M:%S')" \
    --tag nextcloud --tag retention-test /var/lib/nextcloud >/dev/null
done
N1="$(COUNT)"
ok "repo holds $N1 snapshots"

step "prune — policy: hourly×24, daily×14, weekly×6, monthly×6"
PRUNE_OUT="$(nix run .#nc-backup -- prune 2>&1 || true)"
echo "$PRUNE_OUT" | grep -aE 'Remove|remove [0-9]+ snapshots|save' | tail -2
N2="$(COUNT)"
echo "  pruned $((N1 - N2)) snapshots ($N1 → $N2)"
[ "$N2" -lt "$((N1 - 50))" ] || fail "retention policy pruned only $((N1 - N2)) of 100 bucket-saturating snapshots"
[ "$N2" -ge 1 ] || fail "prune deleted everything"
ok "prune enforced"

step "the live snapshot still exists"
RT snapshots --compact | grep -q "^$RID" || fail "live snapshot was pruned!"
nix run .#nc-backup -- validate
ok "live snapshot survived + dump still validates"
