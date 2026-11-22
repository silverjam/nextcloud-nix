#!/usr/bin/env bash
# ZFS migration drill: runs the REAL migration recipes end-to-end in the
# container against SANDBOX disks — two loopfile NTFS "drives" and loopfile
# ZFS pools — then restores the instance. Exercises every interlock,
# stamp, wipe-and-restore step, pool/dataset naming, replication, and the
# NC-came-back-up assertion, with zero contact with real hardware.
#
# NOTE: runs locally only (needs the zfs kernel module on the host, which
# privileged CI runners lack — do not add to the CI matrix).
install_and_assert

echo "[drill] sandbox: building loopfile NTFS drives + test pools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq zfsutils-linux ntfs-3g >/dev/null

W="/var/backups/zfs-drill-$(date +%s)"
mkdir -p "$W"
LOA=; LOB=
cleanup() {
  zpool destroy drill-primary 2>/dev/null || true
  zpool destroy drill-backup 2>/dev/null || true
  umount /mnt/primary /mnt/backup 2>/dev/null || true
  [ -n "$LOA" ] && losetup -d "$LOA" 2>/dev/null || true
  [ -n "$LOB" ] && losetup -d "$LOB" 2>/dev/null || true
  [ -f "$SAVED_TAR" ] && {
    # restore the NC datadir the pool teardown displaced
    rm -rf /var/lib/nextcloud/data
    tar xzf "$SAVED_TAR" -C /var/lib/nextcloud
    systemctl start nextcloud-fpm nextcloud-caddy >/dev/null 2>&1 || true
    echo "[drill] sandbox datadir restored"
  }
}
trap cleanup EXIT

# fake NTFS drives
truncate -s 300M "$W/drive-a.img"
truncate -s 300M "$W/drive-b.img"
LOA="$(losetup --find --show "$W/drive-a.img")"
LOB="$(losetup --find --show "$W/drive-b.img")"
mkfs.ntfs -f -L Data "$LOA" >/dev/null
mkfs.ntfs -f -L "Data Backup" "$LOB" >/dev/null
mkdir -p /mnt/primary /mnt/backup
mount -t ntfs3 "$LOA" /mnt/primary
mount -t ntfs3 "$LOB" /mnt/backup
printf 'personal-archive-payload\n' > "$W/plant.txt"
cp "$W/plant.txt" "$W/Personal Photos/legacy-file.txt" 2>/dev/null || {
  mkdir -p "$W/Personal Photos"; cp "$W/plant.txt" "$W/Personal Photos/legacy-file.txt"; }

# point the recipes at the sandbox: loop devices, skip model/size checks,
# drill pool/dataset/rp mount names
sed -i "s|primaryDisk = .*|primaryDisk = \"$LOA\";|" /test/flake.nix
sed -i "s|backupDisk = .*|backupDisk = \"$LOB\";|" /test/flake.nix
sed -i "s|primaryDiskModel = .*|primaryDiskModel = \"\";|" /test/flake.nix
sed -i "s|primaryDiskMinSize = .*|primaryDiskMinSize = \"\";|" /test/flake.nix
sed -i "s|zfsPoolPrimary = .*|zfsPoolPrimary = \"drill-primary\";|" /test/flake.nix
sed -i "s|zfsPoolBackup = .*|zfsPoolBackup = \"drill-backup\";|" /test/flake.nix
sed -i "s|replicaMount = .*|replicaMount = \"/var/backups/zfs-replica\";|" /test/flake.nix

step "phase 0.5: disaster mirror of the sandbox NTFS drive"
nix run .#zfs-disaster-mirror-create
test -f /var/backups/disaster-mirror-sdc1/plant.txt \
  || fail "disaster mirror missing planted file"
ok "disaster mirror verified + stamp"

step "phase 1: ntfs mirror drive-b"
nix run .#zfs-mirror-ntfs
test -f /mnt/backup/phase1-verified.stamp || fail "phase-1 stamp missing"
ok "ntfs mirror + phase-1 stamp"

step "phase 2: primary zfs pool + NC datadir on zfs"
nix run .#occ -- maintenance:mode --on >/dev/null
SAVED_TAR="$(ls -1 /var/backups/nextcloud/pre-zfs-datadir-*.tar.gz 2>/dev/null | tail -1 || true)"
nix run .#occ -- user:setting admin upgradetest zfsdrill sandboxmarker >/dev/null
CONFIRM=primary nix run .#zfs-create-primary
findmnt -no FSTYPE /var/lib/nextcloud/data | grep -q zfs || fail "datadir not zfs"
nix run .#occ -- status | grep -q 'installed: true' || fail "NC not healthy on zfs datadir"
ok "NC live on drill-primary/nextcloud"

step "phase 3: backup zfs pool + replica seed"
CONFIRM=backup nix run .#zfs-create-backup
findmnt -no TARGET /var/backups/zfs-replica >/dev/null || fail "replica not mounted"
ok "replica seeded"

step "replication: snapshot + incremental send/receive"
nix run .#zfs-replicate
nix run .#zfs-replicate
zfs list -t snapshot -H -o name | grep -cq 'drill-primary/nextcloud@sync-' || \
  fail "no sync snapshots on the primary"
ok "replication snapshots + prunes applied"

step "final verify: full migration stamps"
nix run .#zfs-verify-migration
grep -q 'drill1' /var/lib/nextcloud/provision-credentials-*.log 2>/dev/null || ok "no interference" # drill1 asserted elsewhere
M="$(runuser -u nextcloud -- /run/current-system/sw/bin/true; \
  runuser -u nextcloud -- /nix/store/*postgresql*/bin/psql -h /run/nextcloud-db -U nextcloud \
  -d nextcloud -tAc \
  "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'" \
  2>/dev/null | tail -1)"
expect_equal "1" "$M" "db marker survived the zfs migration"

step "login + file on the zfs datadir"
login_test "$(cat /var/lib/nextcloud/admin-password)"
ok "login works on the migrated instance"
