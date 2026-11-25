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

step "sync timer wired by deploy"
systemctl is-enabled --quiet nextcloud-sync.timer \
  || fail "nextcloud-sync.timer not enabled by deploy"
# the drill drives zfs-replicate by hand; stop the hourly timer so a tick
# cannot race the planted-snapshot retention assertions
systemctl stop nextcloud-sync.timer
ok "hourly sync timer enabled (stopped for the drill)"

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
[ -n "$(find /var/backups/zfs-replica/nextcloud-data -path '*/.zfs' -prune -o -type f -print -quit 2>/dev/null)" ] \
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

step "replication: Sanoid snapshots + Syncoid mirror"
nix run .#zfs-replicate
# awk counts: grep -c exits 1 on zero matches and set -e kills the script
NC_AUTO="$(zfs list -t snapshot -H -o name drill-primary/nextcloud | awk '/@autosnap_/{n++} END{print n+0}')"
[ "$NC_AUTO" -ge 1 ] || fail "sanoid made no autosnap snapshot"
REP_AUTO="$(zfs list -t snapshot -H -o name drill-backup/nextcloud-data | awk '/@autosnap_/{n++} END{print n+0}')"
[ "$REP_AUTO" -ge 1 ] || fail "syncoid replicated no autosnap snapshot"
ok "sanoid snapshots replicated ($NC_AUTO source / $REP_AUTO replica)"

step "replication keeps the datadir and replica mounts separate"
findmnt -no SOURCE /var/lib/nextcloud/data | grep -qx drill-primary/nextcloud \
  || fail "syncoid changed the live datadir mount"
findmnt -no SOURCE /var/backups/zfs-replica/nextcloud-data \
  | grep -qx drill-backup/nextcloud-data \
  || fail "syncoid changed the replica mountpoint"
ok "datadir + replica mountpoints intact"

step "replication: incremental send + target snapshot pruning"
zfs snapshot drill-primary/nextcloud@drill-sync-test
zfs snapshot drill-backup/nextcloud-data@drill-target-only
nix run .#zfs-replicate
zfs list -H -o name drill-backup/nextcloud-data@drill-sync-test >/dev/null 2>&1 \
  || fail "syncoid did not replicate the new snapshot"
zfs list -H -o name drill-backup/nextcloud-data@drill-target-only >/dev/null 2>&1 \
  && fail "syncoid left a target-only snapshot"
zfs destroy drill-primary/nextcloud@drill-sync-test
zfs destroy drill-backup/nextcloud-data@drill-sync-test
ok "incremental send works; target-only snapshots pruned"

step "restic repo replicated to the backup pool"
zfs list -H -o name drill-backup/restic >/dev/null 2>&1 \
  || fail "backup/restic replica dataset missing"
test -e /var/backups/zfs-replica/restic/repo/config \
  || fail "restic repo not replicated to the backup pool"
ok "restic repo has a send/receive replica on drill-backup/restic"

step "snapdir visibility"
nix run .#zfs-snapdir-visible
for ds in drill-primary/nextcloud drill-backup/nextcloud-data \
          drill-primary/restic drill-backup/restic; do
  [ "$(zfs get -H -o value snapdir "$ds")" = visible ] \
    || fail "$ds snapdir not visible"
done
[ -d /var/lib/nextcloud/data/.zfs/snapshot ] \
  || fail ".zfs/snapshot missing on the datadir"
ls /var/lib/nextcloud/data/.zfs/snapshot >/dev/null
ok "snapdir=visible on nextcloud + restic (source and replica)"

step "retention: real Sanoid GFS pruning (VM clock)"
# Sanoid prunes by the snapshot's real ZFS creation time, not by the date
# embedded in its name. Backdating names is therefore useless; move this
# disposable VM's clock back, create an oversupply of genuinely old tier
# snapshots, restore the clock, and run the real Sanoid + Syncoid job.
R="$(nix build .#zfs-replicate --no-link --print-out-paths | tail -1)/bin/zfs-replicate"
CFG="$(grep -oE -- '--configdir=[^ ]+' "$R" | head -1 | cut -d= -f2)"
for p in "hourly = 24" "daily = 7" "weekly = 4" "monthly = 3"; do
  grep -qF "$p" "$CFG/sanoid.conf" || fail "sanoid.conf lost '$p' (config $CFG)"
done

# no timer may fire during the clock jump
systemctl stop nextcloud-backup.timer nextcloud-snapshot.timer \
  nextcloud-cron.timer nextcloud-sync.timer 2>/dev/null || true
timedatectl set-ntp false 2>/dev/null || true
NOW="$(date +%s)"
restore_clock() { date -s "@$NOW" >/dev/null 2>&1 || true; }
trap restore_clock EXIT
BACK=$((NOW - 120 * 86400))
date -s "@$BACK" >/dev/null

mk_snaps() { # <tier> <count>
  local tier="$1" n="$2" i t ts
  for i in $(seq 1 "$n"); do
    t=$((BACK + i * 3600))
    ts="$(date -d "@$t" +%Y-%m-%d_%H:%M:%S)"
    zfs snapshot "drill-primary/nextcloud@autosnap_${ts}_${tier}"
  done
}
mk_snaps hourly 30
mk_snaps daily 10
mk_snaps weekly 6
mk_snaps monthly 5

restore_clock
[ "$(date +%s)" -ge "$((NOW - 60))" ] || fail "guest clock not restored"
trap - EXIT
timedatectl set-ntp true 2>/dev/null || true

# the first sync already left one current autosnap per tier; the planted
# oversupply is 120 days old, so Sanoid must clamp each tier to its count.
# Syncoid only replicates snapshots newer than the replica's base (the
# phase-3 seed), so the planted pre-base history is not backfilled; the
# replica must still have the post-base tier snapshots from the first sync.
nix run .#zfs-replicate
for tier in hourly daily weekly monthly; do
  case "$tier" in
    hourly)  want=24 ;;
    daily)   want=7 ;;
    weekly)  want=4 ;;
    monthly) want=3 ;;
  esac
  got="$(zfs list -t snapshot -H -o name drill-primary/nextcloud \
    | awk -v t="_${tier}" '$0 ~ t"$" {n++} END{print n+0}')"
  [ "$got" -eq "$want" ] || fail "source ${tier} count $got != $want"
  rgot="$(zfs list -t snapshot -H -o name drill-backup/nextcloud-data \
    | awk -v t="_${tier}" '$0 ~ t"$" {n++} END{print n+0}')"
  [ "$rgot" -ge 1 ] || fail "replica has no ${tier} autosnap"
done
ok "Sanoid pruned real-aged snapshots to 24/7/4/3; replica keeps the post-base set"

step "interim archive bind is live before retirement"
systemctl start nextcloud-archive-bind.service
findmnt -no SOURCE "/var/lib/nextcloud/data/archive/files/Archive (Read only)" \
  | grep -qx drill-primary/archive \
  || fail "archive bind did not mount drill-primary/archive"
# index the bind first: the filecache has to hold rows for the interim tree so
# the retirement can be shown to prune them (the drill asserts both sides)
nix run .#occ -- files:scan --path="archive/files/Archive (Read only)" >/dev/null 2>&1
[ "$(Q "SELECT count(*) FROM oc_filecache WHERE path LIKE 'files/Archive (Read only)%'")" -ge 1 ] \
  || fail "interim bind was not indexed into the filecache"
ok "interim archive bind mounted + indexed into the filecache"

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
# the mountpoint is gone, so the retire recipe must have pruned the interim
# tree from the filecache — otherwise datadir-wide indexers (files:scan,
# memories' 15-minute IndexJob) keep failing on the phantom files
[ "$(Q "SELECT count(*) FROM oc_filecache WHERE path LIKE 'files/Archive (Read only)%'")" -eq 0 ] \
  || fail "retire left the interim tree in the filecache"
ok "retire pruned the interim tree from the filecache"
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

step "disaster recovery: promote the backup replica"
# Put a known file into the NC datadir, scan it, and sync before pretending
# the primary pool is gone. The DB/config stay on the root disk; this is the
# real "primary pool failed" recovery: the backup pool must be able to serve
# the Nextcloud datadir, and the replicated restic repo must restore the DB.
marker="replica-promotion-$(date +%s)"
printf '%s\n' "$marker" > /var/lib/nextcloud/data/admin/files/replica-promotion.txt
chown nextcloud:nextcloud /var/lib/nextcloud/data/admin/files/replica-promotion.txt
nix run .#occ -- files:scan admin >/dev/null
# Sanoid may already have taken this hour's snapshot; take an explicit
# marker snapshot so Syncoid has a source snapshot containing the file.
zfs snapshot "drill-primary/nextcloud@promotion-$(date +%s)"
nix run .#zfs-replicate

systemctl stop nextcloud-fpm nextcloud-caddy nextcloud-init \
  nextcloud-cron.timer nextcloud-cron.service nextcloud-sync.timer \
  nextcloud-sync.service nextcloud-backup.timer nextcloud-snapshot.timer \
  nextcloud-backup.service nextcloud-snapshot.service 2>/dev/null || true
umount /var/lib/nextcloud/data
umount /var/backups/restic
umount /drill-primary 2>/dev/null || true
zpool export drill-primary
if zpool list -H -o name 2>/dev/null | grep -qx drill-primary; then
  fail "primary pool still present after export"
fi
ok "primary pool exported (simulated failure)"

# promote the backup datadir to the live path (zfs set mountpoint can
# auto-mount, so only mount explicitly if it is still unmounted)
umount /var/backups/zfs-replica/nextcloud-data
zfs set mountpoint=/var/lib/nextcloud/data drill-backup/nextcloud-data
if ! findmnt -no SOURCE /var/lib/nextcloud/data | grep -qx drill-backup/nextcloud-data; then
  zfs mount drill-backup/nextcloud-data
fi
findmnt -no SOURCE /var/lib/nextcloud/data | grep -qx drill-backup/nextcloud-data \
  || fail "replica datadir not mounted at /var/lib/nextcloud/data"

systemctl start nextcloud-fpm nextcloud-caddy
out=""
for _ in $(seq 1 30); do
  out="$(curl -s -m 5 "$BASE_URL/status.php" || true)"
  echo "$out" | grep -q '"installed":true' && break
  sleep 1
done
echo "$out" | grep -q '"installed":true' \
  || fail "NC did not serve from the promoted replica ($out)"
login_test "$(cat /var/lib/nextcloud/admin-password)"
grep -qx "$marker" /var/lib/nextcloud/data/admin/files/replica-promotion.txt \
  || fail "promoted replica is missing the synced marker file"
PW="$(cat /var/lib/nextcloud/admin-password)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$PW" -X PROPFIND \
  -H 'Depth: 0' "$BASE_URL/remote.php/dav/files/admin/replica-promotion.txt")"
[ "$CODE" = "207" ] || fail "promoted replica file not served over DAV (HTTP $CODE)"
ok "NC serves user data from the backup replica"

# the replicated restic repo is a real backup, not just a dataset copy:
# restore the DB dump from it into a scratch database and check the marker
NCB="$(nix build .#nc-backup --no-link --print-out-paths | tail -1)/bin/nc-backup"
RESTIC="$(grep -oE '/nix/store/[^ ]+-restic-[^/]+/bin/restic' "$NCB" | head -1)"
[ -x "$RESTIC" ] || fail "restic binary not found in the nc-backup build"
RREPO=/var/backups/zfs-replica/restic/repo
RPASS=/var/backups/zfs-replica/restic/.restic-pass
"$RESTIC" -r "$RREPO" --password-file "$RPASS" snapshots --compact >/dev/null \
  || fail "restic replica repo is not readable"
RDIR="$W/restic-replica-restore"
mkdir -p "$RDIR"
"$RESTIC" -r "$RREPO" --password-file "$RPASS" restore latest --target "$RDIR" \
  --include /var/backups/nextcloud/staging/nextcloud.dump
chmod -R a+rX "$RDIR"
DUMP="$RDIR/var/backups/nextcloud/staging/nextcloud.dump"
[ -s "$DUMP" ] || fail "no nextcloud.dump restored from the restic replica"
SCR="nc_dr_$(date +%s)"
runuser -u nextcloud -- "$PGBIN/bin/createdb" -h /run/nextcloud-db -U nextcloud "$SCR"
if ! runuser -u nextcloud -- "$PGBIN/bin/pg_restore" --host=/run/nextcloud-db \
     --username=nextcloud --dbname="$SCR" --jobs=2 "$DUMP"; then
  runuser -u nextcloud -- "$PGBIN/bin/dropdb" -h /run/nextcloud-db -U nextcloud "$SCR" || true
  fail "pg_restore from the restic replica failed"
fi
M="$(runuser -u nextcloud -- "$PGBIN/bin/psql" -h /run/nextcloud-db -U nextcloud \
  -d "$SCR" -tAc "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
[ "$M" = "1" ] || fail "restored DB from replica lost the drill marker (got $M)"
runuser -u nextcloud -- "$PGBIN/bin/dropdb" -h /run/nextcloud-db -U nextcloud "$SCR"
rm -rf "$RDIR"
ok "restic replica restores the DB dump (marker verified)"

# put the real primary back and leave the stack healthy for the final verify
systemctl stop nextcloud-fpm nextcloud-caddy
umount /var/lib/nextcloud/data
zfs set mountpoint=/var/backups/zfs-replica/nextcloud-data drill-backup/nextcloud-data
if ! findmnt -no SOURCE /var/backups/zfs-replica/nextcloud-data | grep -qx drill-backup/nextcloud-data; then
  zfs mount drill-backup/nextcloud-data
fi
# the sandbox pool lives on a loop device, which zpool import does not
# discover by name; point it at the vdev explicitly
zpool import -d "$LOA" drill-primary
zfs mount -a
findmnt -no SOURCE /var/lib/nextcloud/data | grep -qx drill-primary/nextcloud \
  || fail "primary datadir not restored after the promotion drill"
systemctl start nextcloud-fpm nextcloud-caddy
out=""
for _ in $(seq 1 30); do
  out="$(curl -s -m 5 "$BASE_URL/status.php" || true)"
  echo "$out" | grep -q '"installed":true' && break
  sleep 1
done
echo "$out" | grep -q '"installed":true' \
  || fail "NC did not recover after restoring the primary pool ($out)"
ok "primary pool restored; replica mountpoint restored"

step "final verify-migration + teardown"
nix run .#zfs-verify-migration
M="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
expect_equal "1" "$M" "db marker still intact at teardown"
ok "zfs migration pipeline fully rehearsed in-VM"
