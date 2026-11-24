#!/usr/bin/env bash
# VM zfs-drill: runs the REAL ZFS migration recipes against sandbox loop
# disks inside a REAL Ubuntu VM — own kernel, own pool namespace, zero
# contact with the host's zfs state or the drives.
#
# Covers: disaster-mirror → ntfs mirror → create-primary (CONFIRM flow) →
# NC datadir moved onto zfs → create-backup → replicate → verify-migration.
# The sandbox teardown restores the datadir from the phase-2 safety tar.
install_and_assert

step "guest zfs tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq zfsutils-linux ntfs-3g >/dev/null
modprobe zfs 2>/dev/null || {
  apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null
  modprobe zfs
}
zfs version >/dev/null
ok "zfs $(zfs version | head -1) in guest kernel"

# clean prior drill artifacts so repeated runs never fill the disk
rm -rf /var/backups/zfs-drill-* 2>/dev/null || true
W="/var/backups/zfs-drill-$(date +%s)"
SAVED_TAR=""
mkdir -p "$W"
LOA=; LOB=
cleanup() {
  systemctl stop nextcloud-fpm nextcloud-caddy nextcloud-init \
    nextcloud-backup.timer nextcloud-snapshot.timer \
    nextcloud-provision.service nextcloud-cron.timer 2>/dev/null || true
  zpool destroy drill-primary 2>/dev/null || true
  zpool destroy drill-backup 2>/dev/null || true
  umount /mnt/primary /mnt/backup 2>/dev/null || true
  [ -n "$LOA" ] && losetup -d "$LOA" 2>/dev/null || true
  [ -n "$LOB" ] && losetup -d "$LOB" 2>/dev/null || true
  if [ -n "$SAVED_TAR" ] && [ -f "$SAVED_TAR" ]; then
    rm -rf /var/lib/nextcloud/data
    tar xzf "$SAVED_TAR" -C /var/lib/nextcloud
    systemctl start nextcloud-fpm nextcloud-caddy >/dev/null 2>&1 || true
    echo "[drill] datadir restored from safety tar (sandbox teardown)"
  fi
  rm -rf "$W"
}

step "sandbox: loopfile NTFS drives"
# 1G, not 300M: the primary pool now also holds the restic repo, and the
# app-state archive (store-apps) is ~190M — a real backup needs the room
truncate -s 1G "$W/drive-a.img"
truncate -s 1G "$W/drive-b.img"
LOA="$(losetup --find --show "$W/drive-a.img")"
LOB="$(losetup --find --show "$W/drive-b.img")"
mkfs.ntfs -f -L Data "$LOA" >/dev/null
mkfs.ntfs -f -L "Data Backup" "$LOB" >/dev/null
mkdir -p /mnt/primary /mnt/backup
mount -t ntfs3 "$LOA" /mnt/primary
mount -t ntfs3 "$LOB" /mnt/backup
printf 'personal-archive-payload\n' > /var/lib/nextcloud/plant-source.txt 2>/dev/null || true
cp /var/lib/nextcloud/plant-source.txt /mnt/primary/personal-legacy.txt
ok "loop ntfs drives at /mnt/primary + /mnt/backup"

# point the recipes at the sandbox
sed -i "s|primaryDisk = .*|primaryDisk = \"$LOA\";|" /test/flake.nix
sed -i "s|backupDisk = .*|backupDisk = \"$LOB\";|" /test/flake.nix
sed -i "s|primaryDiskModel = .*|primaryDiskModel = \"\";|" /test/flake.nix
sed -i "s|primaryDiskMinSize = .*|primaryDiskMinSize = \"\";|" /test/flake.nix
sed -i "s|zfsPoolPrimary = .*|zfsPoolPrimary = \"drill-primary\";|" /test/flake.nix
sed -i "s|zfsPoolBackup = .*|zfsPoolBackup = \"drill-backup\";|" /test/flake.nix

PGBIN="$(nix build .#postgresql --no-link --print-out-paths | tail -1)"
Q() { runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud \
  -d nextcloud -tAc "$1"; }
nix run .#occ -- user:setting admin upgradetest zfsdrill sandboxmarker >/dev/null

step "phase 0.5: disaster mirror (sandbox ntfs)"
nix run .#zfs-disaster-mirror-create
test -f /var/backups/disaster-mirror-sdc1/personal-legacy.txt \
  || fail "disaster mirror missing planted file"
ok "disaster mirror verified"

step "phase 2: primary zfs pool; NC datadir moves onto zfs"
nix run .#occ -- maintenance:mode --on >/dev/null
umount /mnt/primary /mnt/backup 2>/dev/null || true
step "dry run: create-primary without CONFIRM touches nothing"
OUT="$(nix run .#zfs-create-primary 2>&1)"
echo "$OUT" | grep -aq 'DRY RUN' || fail "create-primary did not dry-run (got: $OUT)"
# the pool name sits on the continuation line of the (backslash-wrapped)
# zpool create, so match the command and its next line together
echo "$OUT" | grep -A1 'zpool create -f' | grep -aq 'drill-primary' \
  || fail "create-primary dry run did not print the real zpool create (got: $OUT)"
zpool list -H -o name 2>/dev/null | grep -qx drill-primary && fail "dry run created the pool"
ok "create-primary is inert without CONFIRM"
CONFIRM=primary nix run .#zfs-create-primary
SAVED_TAR="$(ls -1 /var/backups/nextcloud/pre-zfs-datadir-*.tar.gz 2>/dev/null | tail -1 || true)"
[ -n "$SAVED_TAR" ] || fail "no pre-zfs safety tar found"
findmnt -no FSTYPE /var/lib/nextcloud/data | grep -q zfs || fail "datadir not zfs"
nix run .#occ -- status | grep -q 'installed: true' || fail "NC not healthy on zfs"
M="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
expect_equal "1" "$M" "db marker survived the datadir move"
ok "NC live on drill-primary/nextcloud"

step "resume path: rerun create-primary on the existing pool"
CONFIRM=primary nix run .#zfs-create-primary
findmnt -no FSTYPE /var/lib/nextcloud/data | grep -q zfs || fail "datadir not zfs after resume"
ok "resume path (import + verify, no recreation)"

step "phase 3: backup zfs pool + replica seed"
step "dry run: create-backup without CONFIRM touches nothing"
OUT="$(nix run .#zfs-create-backup 2>&1)"
echo "$OUT" | grep -aq 'DRY RUN' || fail "create-backup did not dry-run (got: $OUT)"
echo "$OUT" | grep -aq 'zfs send -R drill-primary/nextcloud' \
  || fail "create-backup dry run did not print the real seed (got: $OUT)"
zpool list -H -o name 2>/dev/null | grep -qx drill-backup && fail "dry run created the backup pool"
ok "create-backup is inert without CONFIRM"
CONFIRM=backup nix run .#zfs-create-backup
findmnt -no TARGET /var/backups/zfs-replica >/dev/null || fail "replica not mounted"
test -f /var/backups/zfs-replica/archive/personal-legacy.txt \
  || fail "planted legacy file not replicated in archive"
# -print -quit, not a grep pipe: pipefail turns grep -q's early exit into a
# find SIGPIPE (141) and would report an empty replica
[ -n "$(find /var/backups/zfs-replica/nextcloud-data -type f -print -quit 2>/dev/null)" ] \
  || fail "nextcloud datadir replica empty"
ok "replica seeded + personal file replicated"

step "restic repo lives on the primary pool (off the root disk)"
zfs list -H -o name drill-primary/restic >/dev/null 2>&1 \
  || fail "primary/restic dataset missing"
findmnt -no SOURCE /var/backups/restic | grep -qx drill-primary/restic \
  || fail "restic dataset not mounted at /var/backups/restic"
nix run .#nc-backup -- incremental >/dev/null
test -e /var/backups/restic/repo/config \
  || fail "restic repo not initialised on primary/restic"
ok "restic repo lives on drill-primary/restic"

step "replication: two runs (full + incremental)"
nix run .#zfs-replicate
# awk counts: grep -c exits 1 on zero matches and set -e kills the script
PREV_SNAPS="$(zfs list -t snapshot -H -o name 2>/dev/null | awk '/nextcloud@sync-/{n++} END{print n+0}')"
nix run .#zfs-replicate
NEW_SNAPS="$(zfs list -t snapshot -H -o name 2>/dev/null | awk '/nextcloud@sync-/{n++} END{print n+0}')"
[ "$NEW_SNAPS" -gt "$PREV_SNAPS" ] || fail "snapshots not accumulating"
ok "replication applying + snapshot history keeping"

step "restic repo replicated to the backup pool"
zfs list -H -o name drill-backup/restic >/dev/null 2>&1 \
  || fail "backup/restic replica dataset missing"
test -e /var/backups/zfs-replica/restic/repo/config \
  || fail "restic repo not replicated to the backup pool"
ok "restic repo has a send/receive replica on drill-backup/restic"

step "retention: syncs clamp to the keep-48 floor (space-gated prune)"
for i in $(seq 47); do nix run .#zfs-replicate >/dev/null 2>&1; done
N="$(zfs list -t snapshot -H -o name drill-primary/nextcloud | awk '/sync-/{n++} END{print n+0}')"
[ "$N" -eq 48 ] || fail "prune clamp wrong (found $N)"
zfs list -t snapshot -H -o name drill-primary/nextcloud | tail -1 | grep -aq 'sync-' \
  || fail "newest sync snapshot missing"
ok "prune clamped to floor ($N snapshots)"

step "interim archive bind is live before retirement"
systemctl start nextcloud-archive-bind.service
findmnt -no SOURCE "/var/lib/nextcloud/data/archive/files/Archive (Read only)" \
  | grep -qx drill-primary/archive \
  || fail "archive bind did not mount drill-primary/archive"
ok "interim archive bind mounted"

step "retirement: gated destroy of the archive datasets (replicate adapts)"
MS=/var/backups/nextcloud/migration-state
mkdir -p "$MS"
touch "$MS/migration-complete"
ERR="$(nix run .#nc-archive-retire 2>&1 >/dev/null || true)"
echo "$ERR" | grep -aq 'import-complete' \
  || fail "retire did not require import-complete (got: $ERR)"
touch "$MS/import-complete"
ERR="$(nix run .#nc-archive-retire 2>&1 >/dev/null || true)"
echo "$ERR" | grep -aq 'CONFIRM' \
  || fail "retire ran without CONFIRM (got: $ERR)"
# the dry run prints the real destroy commands, not a paraphrase
PLAN="$(nix run .#nc-archive-retire 2>/dev/null || true)"
echo "$PLAN" | grep -aq 'zfs destroy -r drill-primary/archive' \
  || fail "retire dry run did not print the real destroy (got: $PLAN)"
echo "$PLAN" | grep -aq 'zfs destroy -r drill-backup/archive' \
  || fail "retire dry run did not print the replica destroy (got: $PLAN)"
zfs list -H -o name drill-primary/archive >/dev/null 2>&1 \
  || fail "dry run destroyed the archive dataset"
[ ! -f "$MS/archive-retired" ] || fail "dry run stamped archive-retired"
ok "retire is inert without CONFIRM"
CONFIRM=retire-archive nix run .#nc-archive-retire 2>&1 >/dev/null | tail -4
zfs list -H -o name drill-primary/archive >/dev/null 2>&1 \
  && fail "frozen archive dataset survived retirement"
[ -f "$MS/archive-retired" ] || fail "archive-retired stamp missing"
[ ! -e "/var/lib/nextcloud/data/archive/files/Archive (Read only)" ] \
  || fail "retired bind mountpoint still present"
# the unit's ConditionPathExists=!.../archive-retired must keep a manual
# start (and therefore a later deploy) from recreating the empty bind
systemctl start nextcloud-archive-bind.service 2>/dev/null || true
[ ! -e "/var/lib/nextcloud/data/archive/files/Archive (Read only)" ] \
  || fail "post-retire bind start recreated the mountpoint"
systemctl is-active --quiet nextcloud-archive-bind.service \
  && fail "bind unit active after retirement"
REP="$(nix run .#zfs-replicate 2>&1 || true)"
echo "$REP" | tail -3
echo "$REP" | grep -aq 'archive datasets retired' \
  || fail "replicate did not skip the retired archive datasets"
REP="$(nix run .#zfs-replicate 2>&1 || true)"
[ -n "$REP" ] || fail "replicate failed after retirement"
ok "retire gated+executed, replicate adapts"


step "final verify-migration + teardown"
nix run .#zfs-verify-migration
M="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
expect_equal "1" "$M" "db marker still intact at teardown"
ok "zfs migration pipeline fully rehearsed in-VM"
