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
truncate -s 300M "$W/drive-a.img"
truncate -s 300M "$W/drive-b.img"
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

step "phase 1: ntfs mirror to drive-b"
nix run .#zfs-mirror-ntfs
test -f /mnt/backup/phase1-verified.stamp || fail "phase-1 stamp missing"
ok "ntfs mirror + phase-1 stamp"

step "phase 2: primary zfs pool; NC datadir moves onto zfs"
nix run .#occ -- maintenance:mode --on >/dev/null
umount /mnt/primary /mnt/backup 2>/dev/null || true
CONFIRM=primary nix run .#zfs-create-primary
SAVED_TAR="$(ls -1 /var/backups/nextcloud/pre-zfs-datadir-*.tar.gz 2>/dev/null | tail -1 || true)"
[ -n "$SAVED_TAR" ] || fail "no pre-zfs safety tar found"
findmnt -no FSTYPE /var/lib/nextcloud/data | grep -q zfs || fail "datadir not zfs"
nix run .#occ -- status | grep -q 'installed: true' || fail "NC not healthy on zfs"
M="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
expect_equal "1" "$M" "db marker survived the datadir move"
ok "NC live on drill-primary/nextcloud"

step "phase 3: backup zfs pool + replica seed"
CONFIRM=backup nix run .#zfs-create-backup
findmnt -no TARGET /var/backups/zfs-replica >/dev/null || fail "replica not mounted"
test -f /var/backups/zfs-replica/nextcloud-data/personal-legacy.txt \
  || fail "planted file not replicated"
ok "replica seeded + personal file replicated"

step "replication: two runs (full + incremental)"
nix run .#zfs-replicate
PREV_SNAPS="$(zfs list -t snapshot -H -o name | grep -c 'nextcloud@sync-')"
nix run .#zfs-replicate
NEW_SNAPS="$(zfs list -t snapshot -H -o name | grep -c 'nextcloud@sync-')"
[ "$NEW_SNAPS" -gt "$PREV_SNAPS" ] || fail "snapshots not accumulating"
ok "replication applying + snapshot history keeping"

step "final verify-migration + teardown"
nix run .#zfs-verify-migration
M="$(Q "SELECT count(*) FROM oc_preferences WHERE userid='admin' AND appid='upgradetest' AND configkey='zfsdrill'")"
expect_equal "1" "$M" "db marker still intact at teardown"
ok "zfs migration pipeline fully rehearsed in-VM"
