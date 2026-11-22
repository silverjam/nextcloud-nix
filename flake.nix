# Nextcloud deployed with Nix on a plain GNU/Linux host (no NixOS needed).
#
# What this builds:
#   - phpEnv     : PHP 8.4 with every extension Nextcloud needs (CLI + php-fpm)
#   - Caddyfile  : Caddy serving the Nix store copy of Nextcloud, proxying to php-fpm
#   - systemd unit files for: postgres, php-fpm, caddy, init/setup, cron
#   - nextcloud-init : one-shot idempotent bootstrap (db create, installation, config.php)
#   - nextcloud-occ  : `sudo`-wrapped occ CLI that talks to the installed instance
#   - nextcloud-deploy : installer that drops the units into /etc/systemd/system
#                        and enables/starts the stack
#
# Layout (all data lives outside the code, which is immutable in the Nix store):
#   /var/lib/nextcloud       Nextcloud data dir, config/ and store-apps/
#   /var/lib/nextcloud-db    PostgreSQL data dir (unix-socket only; peer auth
#                            for the admin role, scram for the NC app role)
#   /var/lib/nc-caddy        Caddy state dir
#
# Usage:
#   nix run .#deploy                  install / update system units (self-elevates)
#   nix run .#occ -- status           run occ against the installed instance
{
  description = "Nextcloud via Nix: PostgreSQL + PHP-FPM + Caddy as systemd services on Ubuntu";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      # ------------------------------------------------------------------
      # Versions — bump these to upgrade (larger Nextcloud major jumps must
      # go one step at a time; run `nix run .#occ -- upgrade` after deploy).
      # ------------------------------------------------------------------
      nc = pkgs.nextcloud34; # 34.0.x ; pkgs.nextcloud35 available in this pin
      phpBase = pkgs.php84; # Nextcloud-certified
      pg = pkgs.postgresql_17;
      caddy = pkgs.caddy;
      restic = pkgs.restic;

      # ------------------------------------------------------------------
      # Backups (restic) — every archive = db dump + file data pair.
      # See README section "Backups & restore".
      # ------------------------------------------------------------------
      backupRoot = "/var/backups/nextcloud";
      resticRepo = "${backupRoot}/repo";
      stashRoot = "${backupRoot}/staging"; # per-run pg_dump staging
      # same dump path as stored inside archives (no leading slash) — used by
      # restic restore --include during validation
      stashRelDump = lib.removePrefix "/" "${stashRoot}/nextcloud.dump";
      passFile = "${backupRoot}/.restic-pass"; # auto-generated, 0600; repo is
                                           # encrypted but nobody types this.
                                           # Outside ncRoot so `just reset`
                                           # never strands the repo.
      keepHourly = "24";
      keepDaily = "14";
      keepWeekly = "6";
      keepMonthly = "6";

      # User-data directory mirror: rsync data/ -> this target (hourly).
      # Same-disk default = protection against wrong-deletion/config mistakes;
      # point it at a different volume (e.g. /mnt/nc-mirror) for disk failure
      # resilience. Set to "" to disable the job (timers become a no-op).
      dataSyncTarget = "${backupRoot}/data";
      dataSyncTrashDays = "30"; # deletions preserved in <target>/.trash for this many days

      # ------------------------------------------------------------------
      # ZFS storage migration (primary + backup pools); see README "Storage"
      # ------------------------------------------------------------------
      # ------------------------------------------------------------------
      # ZFS migration recipes (host tools; self-promote via sudo) — see
      # README "Storage: migrating to ZFS" for the phase-by-phase procedure
      # ------------------------------------------------------------------
      zfsInstall = pkgs.writeShellScriptBin "zfs-install" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq zfsutils-linux >/dev/null
        modprobe zfs 2>/dev/null || true
        echo "options zfs zfs_arc_max=${arcMax}" > /etc/modprobe.d/zfs-arc.conf
        echo "${arcMax}" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
        systemctl enable --now zfs-import-cache.service zfs-mount.service 2>/dev/null || true
        test -f /lib/systemd/system-generators/zfs-mount-generator \
          || { echo "zfs-mount-generator missing" >&2; exit 1; }
        mkdir -p ${migrationState}
        echo "zfs-ready: $(zfs version | head -1)"
      '';

      zfsRehearse = pkgs.writeShellScriptBin "zfs-rehearse" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        W="/var/backups/zfs-rehearsal-$(date +%s)"
        mkdir -p "$W"
        cleanup() {
          zpool destroy rehearse2 2>/dev/null || true
          zpool destroy rehearse1 2>/dev/null || true
          umount /rehearse1/data /rehearse2/replica 2>/dev/null || true
          losetup -d "$LO1" "$LO2" 2>/dev/null || true
          rm -rf "$W"
        }
        trap cleanup EXIT
        truncate -s 512M "$W/a.img"; truncate -s 512M "$W/b.img"
        LO1="$(losetup --find --show "$W/a.img")"
        LO2="$(losetup --find --show "$W/b.img")"
        echo "[rehearse] throwaway pool create (loopfile)"
        zpool create -f -o ashift=12 -O compression=on -O xattr=sa \
          -O acltype=posixacl -O atime=off rehearse1 "$LO1"
        zfs create rehearse1/data
        printf 'line-1\nline-2\nline-3\nline-4\nline-5\n' > /rehearse1/data/f.txt
        zfs snapshot rehearse1/data@t1
        printf 'line-6\n' > /rehearse1/data/g.txt
        zfs snapshot rehearse1/data@t2
        zpool create -f -o ashift=12 rehearse2 "$LO2"
        echo "[rehearse] full zfs send | receive"
        zfs send -R rehearse1/data@t2 | zfs receive -F rehearse2/replica
        cmp /rehearse1/data/f.txt /rehearse2/replica/f.txt
        cmp /rehearse1/data/g.txt /rehearse2/replica/g.txt
        echo "[rehearse] incremental send | receive"
        printf 'line-7\n' > /rehearse1/data/h.txt
        zfs snapshot rehearse1/data@t3
        zfs send -I rehearse1/data@t2 rehearse1/data@t3 | zfs receive -F rehearse2/replica
        cmp /rehearse1/data/h.txt /rehearse2/replica/h.txt
        echo "[rehearse] PASS — create/dataset/snapshot/incremental/replicate all verified on a throwaway pool"
      '';

      zfsDisasterCreate = pkgs.writeShellScriptBin "zfs-disaster-mirror-create" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        SRC="${primaryMount}"
        [ -d "$SRC" ] || { echo "$SRC not present — run just drive-mount first" >&2; exit 1; }
        findmnt -no SOURCE "$SRC" >/dev/null 2>&1 \
          || { echo "$SRC not mounted — run just drive-mount first" >&2; exit 1; }
        SRCDEV="$(findmnt -no SOURCE "$SRC" 2>/dev/null)" \
          || { echo "$SRC is not mounted" >&2; exit 1; }
        # hardware identity checks only for real disks (sandbox: loop devices
        # have no parent drive; the volume label below is the assertion there)
        # nix bakes primaryDiskModel at eval time — SC2157 sees a literal
        # shellcheck disable=SC2157
        if [ -n "${primaryDiskModel}" ]; then
          PARENT="$(lsblk -no PKNAME "$SRCDEV" | tail -1)"; PARENT="/dev/$PARENT"
          MODEL="$(lsblk -no MODEL "$PARENT")"
          case "$MODEL" in *"${primaryDiskModel}"*) ;; *) echo "refusing: $SRCDEV is not the primary drive (model: $MODEL)" >&2; exit 1;; esac
        fi
        LABEL="$(lsblk -no LABEL "$SRCDEV")"
        [ "$LABEL" = "Data" ] || { echo "refusing: label is '$LABEL', expected 'Data'" >&2; exit 1; }
        echo "disaster-mirror: rsync $SRC ($SRCDEV, ${MODEL:-loop-sandbox}) -> ${disasterMirror}"
        install -d -m 0755 "${disasterMirror}"
        # -xX dropped: NTFS$CI.* xattrs cannot round-trip to ext4 (error 95 per
#          # file); the data + times + hardlinks are what a disaster copy needs
          rsync -aH --numeric-ids --info=progress2 \
          --exclude='/$RECYCLE.BIN' --exclude='/System Volume Information' \
          "$SRC"/ "${disasterMirror}/"
        FS="$(find "$SRC" -type f ! -path '*RECYCLE*' ! -path '*System Volume*' | wc -l)"
        FD="$(find "${disasterMirror}" -type f | wc -l)"
        echo "disaster-mirror: files src=$FS dst=$FD"
        [ "$FD" -ge "$FS" ] || { echo "file count mismatch — rerun to complete" >&2; exit 1; }
        echo "disaster-mirror: spot-checksums (250 random files)"
        BAD=0; N=0
        while IFS= read -r f; do
          rel="''${f#"$SRC"/}"
          N=$((N+1))
          cmp -s "$f" "${disasterMirror}/$rel" || {
            BAD=$((BAD + 1))
            echo "  mismatch: $rel" >&2
          }
        done < <(find "$SRC" -type f ! -path '*RECYCLE*' ! -path '*System Volume*' | shuf -n 250 --random-source=<(yes))
        [ "$BAD" = 0 ] || { echo "$BAD spot-check mismatches" >&2; exit 1; }
        test "$N" -ge 250 || true
        mkdir -p ${migrationState}
        touch ${migrationState}/disaster-mirror-verified
        echo "disaster-mirror: verified ($(du -sh ${disasterMirror} 2>/dev/null | cut -f1) total, $FD files)"
      '';

      zfsDisasterCheck = pkgs.writeShellScriptBin "zfs-disaster-mirror-check" ''
        set -euo pipefail
        test -f ${migrationState}/disaster-mirror-verified \
          && echo "verified" || echo "not verified yet"
        du -sh ${disasterMirror} 2>/dev/null || echo "(missing)"
        echo "files: $(find ${disasterMirror} -type f 2>/dev/null | wc -l)"
      '';

      # interlocked: only after the migration-complete stamp (final verify)
      zfsDisasterRemove = pkgs.writeShellScriptBin "zfs-disaster-mirror-remove" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: migration-complete stamp missing (run zfs-verify-migration first)" >&2; exit 1; }
        test -f ${migrationState}/import-complete \
          || { echo "refusing: import-complete stamp missing (finish nc-import-archive first)" >&2; exit 1; }
        [ "''${CONFIRM:-}" = "disaster" ] \
          || { echo "set CONFIRM=disaster to remove ${disasterMirror}" >&2; exit 1; }
        rm -rf "${disasterMirror}"
        echo "disaster mirror removed — $(df -h / | tail -1 | awk '{print $4}') free on /"
      '';

      ncImportArchive = pkgs.writeShellScriptBin "nc-import-archive" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        # sudo env_reset strips PATH; re-arm what the tail may need
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
        OCC() {
          /usr/bin/sudo -u ${ncUser} env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} \
            ${phpEnv}/bin/php ${nc}/occ "$@"
        }

        # gates: only after a verified migration, with the owner provisioned
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: run zfs-verify-migration first" >&2; exit 1; }
        [ -d "${archiveSource}" ] \
          || { echo "${archiveSource} missing — archive dataset gone?" >&2; exit 1; }
        OCC user:info ${archiveOwner} >/dev/null \
          || { echo "user ${archiveOwner} not provisioned (add to provisionedUsers, deploy)" >&2; exit 1; }

        # share name: oldest file year in the source; stamped once, never renamed
        STATE="${migrationState}/import-share-name"
        if [ -s "$STATE" ]; then
          NAME="$(cat "$STATE")"
        else
          OLD="$(find "${archiveSource}" -type f -printf '%T+\n' 2>/dev/null | sort | head -1 | cut -d- -f1)"
          case "$OLD" in
            1[89][0-9][0-9]|20[0-9][0-9]) ;;
            *) OLD="$(date +%Y)" ;;
          esac
          NAME="Archive $OLD-$(date +%Y)"
          printf %s "$NAME" > "$STATE"
        fi
        TDIR="${ncDataDir}/${archiveOwner}/files/$NAME"
        echo "archive: importing ${archiveSource} -> $TDIR"

        # one-time resumable copy; a count stamp makes reruns skip it
        CNT="${migrationState}/import-file-count"
        if [ -s "$CNT" ]; then
          echo "archive: already imported ($(< "$CNT") files) — skipping the copy pass"
        else
          install -d -m 0770 -o ${ncUser} -g ${ncUser} "$TDIR"
          rsync -aH --chown=${ncUser}:${ncUser} --info=progress2 \
            --exclude '/System Volume Information' --exclude '/$RECYCLE.BIN' \
            "${archiveSource}/" "$TDIR"/
          FS="$(find "${archiveSource}" -type f | wc -l)"
          FD="$(find "$TDIR" -type f | wc -l)"
          echo "archive: files src=$FS dst=$FD"
          [ "$FD" -ge "$FS" ] || { echo "count mismatch — rerun to complete" >&2; exit 1; }
          BAD=0
          while IFS= read -r f; do
            rel="''${f#"${archiveSource}"/}"
            cmp -s "$f" "$TDIR/$rel" || { BAD=$((BAD + 1)); echo "  mismatch: $rel" >&2; }
          done < <(find "${archiveSource}" -type f | shuf -n 250 --random-source=<(yes))
          [ "$BAD" = 0 ] || { echo "$BAD spot-check mismatches" >&2; exit 1; }
          chown -R ${ncUser}:${ncUser} "$TDIR"
          printf %s "$FD" > "$CNT"
        fi
        echo "archive: scanning into the filecache"
        OCC files:scan ${archiveOwner}

        # group share via the OCS API as the owner (the owner's own password
        # comes from the 0600 provision-credentials log — machine hex)
        PW="$(grep -ah "^uid=${archiveOwner} password=" ${ncRoot}/provision-credentials-*.log 2>/dev/null \
          | sed -E 's/^uid=[^ ]+ password=([^ ]+).*/\1/' | tail -1 || true)"
        [ -n "$PW" ] \
          || { echo "no credentials for ${archiveOwner} on file — share by hand or re-provision" >&2; exit 1; }
        EXIST="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' -G \
          --data-urlencode "path=/$NAME" \
          "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json" \
          | grep -aoE '"share_with":"${archiveShareGroup}"' | wc -l || true)"
        if [ "$EXIST" -ge 1 ]; then
          echo "archive: ${archiveShareGroup} share already present"
        else
          RESP="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' \
            --data-urlencode "path=/$NAME" \
            --data-urlencode "shareType=3" \
            --data-urlencode "shareWith=${archiveShareGroup}" \
            --data-urlencode "permissions=${archiveSharePerms}" \
            "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json")"
          echo "$RESP" | grep -aq '"statuscode":200' \
            || { echo "share creation failed: $RESP" >&2; exit 1; }
        fi

        touch ${migrationState}/import-complete
        echo "archive: import complete — '$NAME' shared with ${archiveShareGroup}"
      '';

      ncArchiveShare = pkgs.writeShellScriptBin "nc-archive-share" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
        OCC() {
          /usr/bin/sudo -u ${ncUser} env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} \
            ${phpEnv}/bin/php ${nc}/occ "$@"
        }
        # gates: verified migration + the bind mounted + the owner provisioned
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: run zfs-verify-migration first" >&2; exit 1; }
        findmnt -no SOURCE "${archiveBindWhere}" \
          || { echo "${archiveBindWhere} is not bind-mounted — start the bind unit first" >&2; exit 1; }
        OCC user:info ${archiveOwner} >/dev/null \
          || { echo "user ${archiveOwner} not provisioned" >&2; exit 1; }

        TDIR="${archiveBindWhere}"
        # systemd auto-created the mountpoint hierarchy root-owned — the home
        # tree dirs must be nextcloud-owned or the home-storage check fails
        # ("files subdirectory missing") and the scan/share treat it read-only
        install -d -o ${ncUser} -g ${ncUser} -m 0700 "${ncDataDir}/${archiveOwner}"
        install -d -o ${ncUser} -g ${ncUser} -m 0700 "${ncDataDir}/${archiveOwner}/files"
        install -d -o ${ncUser} -g ${ncUser} -m 0770 "${ncDataDir}/${archiveOwner}/files/${archiveBindMountName}" 2>/dev/null || true
        # group-writable pass so the NC process can move deletes into trash
        PERM="${migrationState}/archive-perms-done"
        if [ ! -s "$PERM" ]; then
          chgrp -R ${ncUser} "${archiveSource}"
          find "${archiveSource}" -type d -exec chmod g+rwX {} +
          find "${archiveSource}" -type d -exec chmod g+s {} + 2>/dev/null || true
          find "${archiveSource}" -type f -exec chmod g+rw {} +
          date -u > "$PERM"
          echo "archive: group-writable pass done"
        fi
        echo "archive: scanning $TDIR into the filecache"
        NAME="${archiveBindMountName}"
        # targeted scan: the full-user scan stops at the bind-mountpoint,
        # while --path walks straight through
        OCC files:scan --path="${archiveOwner}/files/$NAME"

        # member shares via the OCS API as the owner (password from the 0600 log)
        # NC 34 silently drops type-3 group-share recipients (share_with lands
        # empty + default perms) — share each group member directly instead
        PW="$(grep -ah "^uid=${archiveOwner} password=" ${ncRoot}/provision-credentials-*.log 2>/dev/null \
          | sed -E 's/^uid=[^ ]+ password=([^ ]+).*/\1/' | tail -1 || true)"
        [ -n "$PW" ] \
          || { echo "no credentials for ${archiveOwner} on file — share by hand or re-provision" >&2; exit 1; }
        NAME="${archiveBindMountName}"
        MEMBERS="$(OCC group:list --output=json 2>/dev/null | python3 -c "import json,sys
print(' '.join(sorted(json.load(sys.stdin).get('${archiveShareGroup}', []))))")"
        [ -n "$MEMBERS" ] \
          || { echo "group ${archiveShareGroup} empty or missing — nothing to share with" >&2; exit 1; }
        HELD="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' -G \
          --data-urlencode "path=/$NAME" \
          "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json" \
          | grep -aoE '"share_with":"[a-z0-9_.@-]+"' || true)"
        CREATED=0
        for m in $MEMBERS; do
          [ "$m" = "${archiveOwner}" ] && continue
          case "$HELD" in
            *"share_with\":\"$m\""*) continue ;;
          esac
          RESP="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' \
            --data-urlencode "path=/$NAME" \
            --data-urlencode "shareType=0" \
            --data-urlencode "shareWith=$m" \
            --data-urlencode "permissions=${archiveSharePerms}" \
            "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json")"
          echo "$RESP" | grep -aq '"statuscode":200' \
            || { echo "share with member $m failed: $RESP" >&2; exit 1; }
          CREATED=$((CREATED + 1))
          echo "archive: shared '$NAME' with member $m (${archiveSharePerms})"
        done
        [ "$CREATED" = 0 ] && echo "archive: member shares already present for all of ${archiveShareGroup}"
        echo "archive: '$NAME' shared with ${archiveShareGroup} members (interim bind; option B replaces it)"
      '';

      zfsProvisionedPasswords = pkgs.writeShellScriptBin "provisioned-passwords" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        UIDF="''${1:-}"
        found=0
        for f in ${ncRoot}/provision-credentials-*.log; do
          [ -f "$f" ] || continue
          if [ -n "$UIDF" ]; then
            grep -a "^uid=$UIDF " "$f" && found=1
          else
            cat "$f" && found=1
          fi
        done
        if [ "$found" = 0 ]; then
          echo "(no provisioned credentials on file)"
          exit 0
        fi
        echo
        echo "NOTE: these are the initial passwords generated at user creation."
        echo "If a password was changed afterwards (user:resetpassword / web UI),"
        echo "the current one differs."
      '';

      primaryDisk = "/dev/disk/by-id/ata-ST2000DL001-9VT156_5YD1BHCZ-part1"; # sdc1, USB3
      backupDisk = "/dev/disk/by-id/ata-ST2000DL003-9VT166_6YD055P4-part1"; # sdb1
      primaryDiskModel = "ST2000DL001";
      primaryDiskMinSize = "2000000000000";
      zfsPoolPrimary = "primary";
      zfsPoolBackup = "backup";
      ncDataset = "${zfsPoolPrimary}/nextcloud"; # mounts at the nc datadir
      archiveDataset = "${zfsPoolPrimary}/archive"; # personal content, /mnt/archive
      replicaDataset = "${zfsPoolBackup}/nextcloud-data";
      replicaMount = "/var/backups/zfs-replica";
      arcMax = "8589934592"; # 8G of 30G RAM
      zfsKeepSnapshots = "48"; # snapshot floor per dataset (never pruned below)
      primaryPruneMinFree = "161061273600"; # 150 GiB: prune primary history only below this
      replicaPruneMinFree = "107374182400"; # 100 GiB: prune replica history only below this
      # archive import (plan of record): copy the archive dataset into a
      # service user's folder and group-share it; completes with import-complete
      archiveOwner = "archive";
      archiveShareGroup = "parents";
      archiveSharePerms = "15"; # read+change+create+delete, no re-share
      archiveSource = "/mnt/archive";
      ncWebUrl = "http://127.0.0.1:${webPort}";
      # interim: the archive dataset binds INTO the datadir (zero copy) and is
      # served as a native shared folder; option B's copy replaces this later
      archiveBindMountName = "Archive";
      archiveBindWhere = "${ncDataDir}/${archiveOwner}/files/${archiveBindMountName}";
      archiveBindMountUnit = pkgs.writeText "var-lib-nextcloud-data-archive-files-Archive.mount" ''
        [Unit]
        Description=Nextcloud archive dataset bind-mounted into the datadir (interim)
        ConditionPathIsDirectory=${archiveSource}
        # the bind lands INSIDE the archive user's home — the account must
        # exist first (its creation refuses when the home already holds files)
        # Requires pulls init AND provision into the transaction (After only
        # orders — without the pull, provision spawned before init created
        # ncRoot and died at namespace setup); the account must exist before
        # its home holds files
        Requires=nextcloud-init.service nextcloud-provision.service
        After=nextcloud-init.service nextcloud-provision.service
        [Mount]
        What=${archiveSource}
        Where=${archiveBindWhere}
        Type=none
        Options=bind
        [Install]
        WantedBy=multi-user.target
      '';

      migrationState = "${backupRoot}/migration-state"; # interlock stamps
      disasterMirror = "/var/backups/disaster-mirror-sdc1"; # root-disk full copy
      primarySrcMount = "/mnt/primary"; # sdc1 "Data" volume (drives-mount)
      primaryMount = "/mnt/primary"; # sdc1 NTFS mount (ro during migration)
      backupMount = "/mnt/backup"; # sdb1 "Data Backup" NTFS mount (ro)
      primaryUuid = "3E94E6D594E68F29"; # sdc1 NTFS filesystem uuid
      backupUuid = "6A18D70F18D6D8E1"; # sdb1 NTFS filesystem uuid

      # ------------------------------------------------------------------
      # drive mount tools (migration-only; NTFS volumes, read-only + force)
      # ------------------------------------------------------------------
      drivesCheck = pkgs.writeShellScriptBin "drives-check" ''
        set -euo pipefail
        M1="${primaryMount}"; U1="${primaryUuid}"
        M2="${backupMount}"; U2="${backupUuid}"
        st() {
          if findmnt -S "UUID=$1" >/dev/null 2>&1; then
            echo "  $2: mounted at $(findmnt -no TARGET -S "UUID=$1") (fstype $(findmnt -no FSTYPE -S "UUID=$1"), ro=$(findmnt -no OPTIONS -S "UUID=$1" | grep -co ro))"
          elif [ -b "/dev/disk/by-uuid/$1" ]; then
            echo "  $2: connected, NOT mounted (fs $(lsblk -no FSTYPE "/dev/disk/by-uuid/$1"))"
          else
            echo "  $2: not connected (by-uuid $1 absent)"
          fi
        }
        echo "== drive status =="
        st "$U1" "primary ($M1)"
        st "$U2" "backup  ($M2)"
      '';

      drivesMount = pkgs.writeShellScriptBin "drives-mount" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        # migration-only mounts: READ-ONLY + force (both NTFS volumes carry
        # the dirty bit; nothing in the migration phases ever writes to them)
        for pair in "${primaryUuid}|${primaryMount}" "${backupUuid}|${backupMount}"; do
          uuid="''${pair%%|*}"; mp="''${pair##*|}"
          if findmnt "$mp" >/dev/null 2>&1; then
            echo "drives-mount: $mp already mounted"
            continue
          fi
          dev="/dev/disk/by-uuid/$uuid"
          if [ ! -b "$dev" ]; then
            echo "drives-mount: WARNING $dev not connected — skipping (phases needing it will refuse)"
            continue
          fi
          install -d -m 0755 "$mp"
          mount -t ntfs3 -o ro,force "$dev" "$mp"
          echo "drives-mount: $dev -> $mp (ro,force)"
        done
      '';

      drivesUmount = pkgs.writeShellScriptBin "drives-umount" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        for mp in "${primaryMount}" "${backupMount}"; do
          findmnt "$mp" >/dev/null 2>&1 && umount "$mp" && echo "drives-umount: $mp" || true
        done
      '';

      # Optional DECLARATIVE user provisioning (creation-side only).

      # Users are runtime state like files — removal from this list is a
      # no-op (never delete a user from config), and passwords of existing
      # users are never rotated. New users get a one-shot generated password
      # appended to /var/lib/nextcloud/provision-credentials-*.log (0600).
      #   provisionedUsers = {
      #     alice = { displayName = "Alice"; quota = "2 GB"; groups = [ "family" ]; };
      #   };
      provisionedUsers = { 
        jason = { displayName = "Jason Mobarak"; groups = ["family" "parents"]; };
        archive = { displayName = "Family Archive"; }; # shared-archive owner (no quota)
        josphine = { displayName = "Josephine Sheng"; groups = ["family" "parents"]; };
        addie = { displayName = "Addie Mobarak"; groups = ["family" "kids"]; };
        thaelia = { displayName = "Thaelia Mobarak"; groups = ["family" "kids"]; };
        richard = { displayName = "Richard Mobarak"; groups = ["family"]; };
      };
      # Explicit removal list — the ONLY way a provisioned user is deleted.
      # For each entry that still exists, a per-user backup is taken first
      # (files + full pg_dump into /var/backups/nextcloud/deprovisioned/<uid>/<ts>/)
      # and the deletion aborts if that backup cannot be verified. Entries
      # are self-draining: once the user is gone they are a no-op.
      deprovisionedUsers = [ ];
      # render per-user specs: uid<TAB>display<TAB>quota<HAB>groups(;-sep)
      provisionSpecLines = lib.mapAttrsToList
        (name: u:
          lib.concatStringsSep "\t" [
            name
            (u.displayName or "")
            (u.quota or "")
            (lib.concatStringsSep ";" (u.groups or [ ]))
          ])
        provisionedUsers;
      provisionShellArray = lib.concatStringsSep " "
        (map lib.escapeShellArg provisionSpecLines);
      removeShellArray = lib.concatStringsSep " "
        (map lib.escapeShellArg deprovisionedUsers);

      # ------------------------------------------------------------------
      # Names & paths (single source of truth for units, Caddyfile, scripts)
      # ------------------------------------------------------------------
      ncUser = "nextcloud";
      webUser = "nc-caddy"; # caddy runs as this, gets socket access via group
      ncRoot = "/var/lib/nextcloud"; # nextcloud state root
      ncConfig = "${ncRoot}/config"; # config.php lives here (NEXTCLOUD_CONFIG_DIR)
      ncDataDir = "${ncRoot}/data"; # nextcloud 'datadir' (user files)
      ncStoreApps = "${ncRoot}/store-apps"; # writable apps from the app store
      dbRoot = "/var/lib/nextcloud-db";
      dbSock = "/run/nextcloud-db"; # socket dir (no TCP, peer auth)
      fpmSock = "/run/nextcloud/php-fpm.sock";
      webPort = "55555"; # Caddy's plain-HTTP port on the LAN; tailscale
                         # fronts it with TLS (see README / `just tailscale`)
      unitDir = "/etc/systemd/system";

      # ------------------------------------------------------------------
      # PHP with the extensions Nextcloud requires
      # ------------------------------------------------------------------
      phpIniExtra = ''
        ; ---- Nextcloud requirements ----
        memory_limit = 1G
        upload_max_filesize = 10G
        post_max_size = 10G
        output_buffering = 0
        max_execution_time = 3600
        max_input_time = 3600
        expose_php = Off
        ; ---- caching (single-server: APCu for both) ----
        apc.enable_cli = 1
        apc.shm_size = 512M
        ; ---- opcache ----
        opcache.interned_strings_buffer = 8
        opcache.max_accelerated_files = 10000
        opcache.memory_consumption = 128
        opcache.revalidate_freq = 1
        ; ---- trust the distro CA bundle for outbound HTTPS (app store etc.) ----
        openssl.cafile = /etc/ssl/certs/ca-certificates.crt
      '';

      phpEnv =
        (phpBase.buildEnv {
          extraConfig = phpIniExtra;
        }).override
          {
            extensions =
              { enabled, all }:
              let
                want = with all; [
                  apcu
                  bcmath
                  bz2
                  ctype
                  curl
                  dom
                  exif
                  fileinfo
                  filter
                  gd
                  gmp
                  iconv
                  imagick
                  intl
                  mbstring
                  openssl
                  pcntl
                  pdo
                  pdo_pgsql
                  posix
                  session
                  simplexml
                  sodium
                  xmlreader
                  xmlwriter
                  zip
                  zlib
                ];
              in
              enabled ++ (lib.subtractLists enabled want);
          };

      # ------------------------------------------------------------------
      # php-fpm pool (master runs as nextcloud in the systemd unit)
      # ------------------------------------------------------------------
      phpFpmConf = pkgs.writeText "php-fpm-nextcloud.conf" ''
        [global]
        daemonize = no
        ; log via syslog (/dev/log -> journald). /dev/stderr cannot be reopened
        ; by php-fpm (systemd attaches stderr as a socket) and the compiled-in
        ; default points into the read-only store, which breaks startup
        error_log = syslog

        [nextcloud]
        user = ${ncUser}
        group = ${ncUser}
        listen = ${fpmSock}
        ; fpm runs as nextcloud (non-root): it may only chown() the socket to
        ; its own uid/gid — caddy's nc-caddy user is a member of :nextcloud
        listen.owner = ${ncUser}
        listen.group = ${ncUser}
        listen.mode = 0660
        pm = dynamic
        pm.max_children = 10
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        pm.max_requests = 500
        catch_workers_output = yes
        decorate_workers_output = no
        clear_env = no
        ; log stack traces of requests running longer than 10s
        ; (`just slowlog` to read them — they land in the nextcloud state dir)
        request_slowlog_timeout = 10s
        slowlog = ${ncRoot}/php-slow.log
      '';

      # ------------------------------------------------------------------
      # Caddyfile (plain HTTP for LAN; see README for Tailscale HTTPS fronting)
      # ------------------------------------------------------------------
      caddyfile = pkgs.writeText "nextcloud-Caddyfile" ''
        {
          admin off
          auto_https off
          # tailscale serve connects from loopback and sends the real client's
          # X-Forwarded-Proto — trust it so NC sees HTTPS instead of http
          servers {
            trusted_proxies static 127.0.0.1/32
          }
        }

        http://:${webPort} {
          root * ${nc}
          file_server

          # access logs -> stderr -> journald (`just follow nextcloud-caddy`)
          log {
            output stderr
          }

          # Don't serve code/tools that should only be executed (mirrors the
          # official nginx "deny" list) and never expose dotfiles.
          @protected {
            path /build/* /tests/* /config/* /lib/* /3rdparty/* /templates/* \
                 /occ /console.php /autotest* /.htaccess* /.user.ini /.git*
          }
          respond @protected 404

          # CalDAV / CardDAV discovery
          redir /.well-known/carddav /remote.php/dav 301
          redir /.well-known/caldav /remote.php/dav 301

          php_fastcgi unix/${fpmSock} {
            env front_controller_active true
          }

          header {
            -Server
            -X-Powered-By
            X-Content-Type-Options nosniff
            X-Frame-Options SAMEORIGIN
            Referrer-Policy no-referrer
            X-Robots-Tag noindex, nofollow
          }

          encode gzip zstd

          request_body {
            max_size 10GB
          }
        }
      '';

      # ------------------------------------------------------------------
      # systemd units
      # ------------------------------------------------------------------
      dbUnit = pkgs.writeText "nextcloud-db.service" ''
        [Unit]
        Description=Nextcloud PostgreSQL database (Nix-managed)

        [Service]
        Type=simple
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        RuntimeDirectory=nextcloud-db
        RuntimeDirectoryMode=0755
        StateDirectory=nextcloud-db
        StateDirectoryMode=0700
        ExecStartPre=${dbInit}
        ExecStart=${pg}/bin/postgres -D ${dbRoot} -k ${dbSock} -h ""
        ExecStartPost=${dbReady}
        Restart=on-failure
        RestartSec=3
        TimeoutStopSec=120
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ProtectKernelTunables=true
        ProtectKernelModules=true
        ProtectControlGroups=true
        RestrictAddressFamilies=AF_UNIX
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target
      '';

      fpmUnit = pkgs.writeText "nextcloud-fpm.service" ''
        [Unit]
        Description=Nextcloud PHP-FPM backend (Nix-managed)
        After=nextcloud-db.service

        [Service]
        Type=simple
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        RuntimeDirectory=nextcloud
        RuntimeDirectoryMode=0755
        StateDirectory=nextcloud
        ExecStartPre=${phpEnv}/bin/php-fpm --test --fpm-config ${phpFpmConf}
        ExecStart=${phpEnv}/bin/php-fpm --fpm-config ${phpFpmConf}
        ExecReload=${pkgs.coreutils}/bin/kill -USR2 $MAINPID
        Restart=on-failure
        RestartSec=3
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ProtectKernelTunables=true
        ProtectKernelModules=true
        ProtectControlGroups=true
        RestrictAddressFamilies=AF_UNIX
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target
      '';

      caddyUnit = pkgs.writeText "nextcloud-caddy.service" ''
        [Unit]
        Description=Nextcloud web server (Caddy, Nix-managed)
        Wants=nextcloud-fpm.service
        After=nextcloud-fpm.service

        [Service]
        Type=simple
        User=${webUser}
        Group=${webUser}
        UMask=0022
        StateDirectory=nc-caddy
        StateDirectoryMode=0750
        Environment="XDG_DATA_HOME=/var/lib/nc-caddy"
        Environment="XDG_CONFIG_HOME=/var/lib/nc-caddy"
        ExecStart=${caddy}/bin/caddy run --config ${caddyfile} --adapter caddyfile
        Restart=on-failure
        RestartSec=3
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ProtectKernelTunables=true
        ProtectKernelModules=true
        ProtectControlGroups=true
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target
      '';

      initUnit = pkgs.writeText "nextcloud-init.service" ''
        [Unit]
        Description=Nextcloud init & config bootstrap (Nix-managed)
        After=nextcloud-db.service
        Requires=nextcloud-db.service

        [Service]
        Type=oneshot
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        RemainAfterExit=true
        TimeoutStartSec=15min
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        StateDirectory=nextcloud
        ExecStart=${initScript}

        [Install]
        WantedBy=multi-user.target
      '';

      cronUnit = pkgs.writeText "nextcloud-cron.service" ''
        [Unit]
        Description=Nextcloud background jobs via cron (Nix-managed)
        After=nextcloud-init.service
        Requires=nextcloud-init.service

        [Service]
        Type=oneshot
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${phpEnv}/bin/php ${nc}/occ background:cron
      '';

      cronTimer = pkgs.writeText "nextcloud-cron.timer" ''
        [Unit]
        Description=Run Nextcloud background jobs every 5 minutes (Nix-managed)

        [Timer]
        OnBootSec=3min
        OnUnitActiveSec=5min

        [Install]
        WantedBy=timers.target
      '';

      # ------------------------------------------------------------------
      # helper scripts
      # ------------------------------------------------------------------

      # Initialises the postgres data dir on first start and (re)writes the
      # stack-managed auth config on every start.
      dbInit = pkgs.writeShellScript "nextcloud-db-init" ''
        if [ ! -s "${dbRoot}/PG_VERSION" ]; then
          echo "nextcloud-db: initialising data dir in ${dbRoot}"
          ${pg}/bin/initdb \
            --pgdata=${dbRoot} \
            --username=${ncUser} \
            --encoding=UTF8 \
            --locale=C.UTF-8 \
            --auth-local=peer \
            --auth-host=scram-sha-256
        fi
        # Auth model (unix socket only — the unit starts postgres with -h "",
        # no TCP lines). Declarative & stack-owned: rewritten on every start.
        #  - bootstrap/admin role `nextcloud`: OS-level peer auth everywhere
        #    (it has no stored password — peer only ever)
        #  - oc_* app roles the NC installer creates (with its own random
        #    password): scram-sha-256, scoped via a user-name regex so the
        #    line can never swallow peer-auth connections
        {
          echo '# managed by nextcloud-db-init (Nix) — do not edit, changes get overwritten'
          echo '# oc_* app roles: password (scram) auth on the app database'
          echo 'local  nextcloud  /^oc_  scram-sha-256'
          echo '# everything else: peer auth (OS user == role)'
          echo 'local  all        all     peer'
        } > "${dbRoot}/pg_hba.conf"
      '';

      # Blocks until postgres actually accepts connections on its socket so
      # ordered units (nextcloud-init) never race startup readiness.
      dbReady = pkgs.writeShellScript "nextcloud-db-ready" ''
        for i in $(seq 1 120); do
          if ${pg}/bin/pg_isready -q -h ${dbSock} 2>/dev/null; then
            echo "nextcloud-db: accepting connections"
            exit 0
          fi
          sleep 0.5
        done
        echo "nextcloud-db: pg_isready timed out waiting for socket" >&2
        exit 1
      '';

      # Re-applies nix-owned values to config.php (idempotent; safe on every
      # deploy — keeps the pinned store path for the read-only app dir in sync
      # with the current build).
      applyConfig = pkgs.writeText "nextcloud-apply-config.php" ''
        <?php
        $configFile = '${ncConfig}/config.php';
        if (!file_exists($configFile)) {
          fwrite(STDERR, "nextcloud-apply-config: ${ncConfig}/config.php missing; install first\n");
          exit(1);
        }
        require $configFile;
        $CONFIG['apps_paths'] = [
          [ 'path' => '${nc}/apps',        'url' => '/apps',       'writable' => false ],
          [ 'path' => '${ncStoreApps}',    'url' => '/store-apps', 'writable' => true  ],
        ];
        $CONFIG['memcache.local']  = '\\OC\\Memcache\\APCu';
        $CONFIG['memcache.locking'] = '\\OC\\Memcache\\APCu';
        $CONFIG['trashbin_retention_obligation']  = 'disabled'; // trash persists until manually expunged
        $CONFIG['versions_retention_obligation']  = 'disabled'; // file versions persist until manually purged
        file_put_contents($configFile, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");
        chmod($configFile, 0640);
        echo "nextcloud-apply-config: OK\n";
      '';

      # One-shot bootstrap: db, first-time install, trusted domains, hardening.
      initScript = pkgs.writeShellScript "nextcloud-init-run" ''
        set -euo pipefail

        mkdir -p "${ncDataDir}" "${ncConfig}" "${ncStoreApps}"
        [ -e "${ncDataDir}/.ocdata" ] || : > "${ncDataDir}/.ocdata"

        # --- database ---
        PSQLO() { ${pg}/bin/psql -h ${dbSock} -U ${ncUser} -d postgres "$@"; }

        if ! PSQLO -tAc "SELECT 1 FROM pg_database WHERE datname = 'nextcloud'" | grep -q 1; then
          echo "nextcloud-init: creating database 'nextcloud'"
          ${pg}/bin/createdb -h ${dbSock} -U ${ncUser} nextcloud
        fi

        # Tidy roles left behind by aborted installs — only when no instance
        # is installed (config.php absent ⇒ no data to lose). Never touches
        # db data otherwise.
        if [ ! -f "${ncConfig}/config.php" ]; then
          for r in $(PSQLO -tAc "SELECT rolname FROM pg_roles WHERE rolname LIKE 'oc\_%'"); do
            PSQLO -c "DROP ROLE IF EXISTS \"$r\"" || true
          done
        fi

        # --- database (createdb is a no-op if it exists) ---
        if ! PSQLO -tAc "SELECT 1 FROM pg_database WHERE datname = 'nextcloud'" | grep -q 1; then
          echo "nextcloud-init: creating database 'nextcloud'"
          ${pg}/bin/createdb -h ${dbSock} -U ${ncUser} nextcloud
        fi

        RUNOCC() { ${phpEnv}/bin/php ${nc}/occ "$@"; }

        # Apply nix-owned config values BEFORE any occ call. After an
        # NC major swap, occ cannot even boot while config.php still pins
        # the old store's apps_paths (old-tree apps crash the new core).
        # On a first install there is no config.php yet — skip silently.
        ${phpEnv}/bin/php ${applyConfig} 2>&1 \
          || echo "  (apply-config skipped — no config.php yet)"

        # --- first-time installation (idempotent) ---
        if ! RUNOCC status 2>/dev/null | grep -q 'installed: true'; then
          echo "nextcloud-init: first-time install (may take a couple of minutes)"
          if [ ! -s "${ncRoot}/admin-password" ]; then
            ${pkgs.openssl}/bin/openssl rand -hex 16 > "${ncRoot}/admin-password"
            chmod 0600 "${ncRoot}/admin-password"
          fi
          ADMIN_PW="$(cat "${ncRoot}/admin-password")"
          # the setup/admin connection itself is peer-auth'd; this value just
          # satisfies maintenance:install's prompt requirement (the oc_* app
          # role the installer creates gets its own random password)
          DB_PASS="$(${pkgs.openssl}/bin/openssl rand -hex 16)"
          RUNOCC maintenance:install \
            --database pgsql \
            --database-name nextcloud \
            --database-host ${dbSock} \
            --database-user ${ncUser} \
            --database-pass "$DB_PASS" \
            --admin-user admin \
            --admin-pass "$ADMIN_PW" \
            --data-dir ${ncDataDir}
        fi

        # --- nix-owned config.php values (fresh store path every deploy) ---
        ${phpEnv}/bin/php ${applyConfig}

        # --- trusted domains: localhost, hostname, primary LAN IP ---
        RUNOCC config:system:set trusted_domains 0 --value localhost
        RUNOCC config:system:set trusted_domains 1 --value "$(hostname)"
        LANIP="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"
        if [ -n "$LANIP" ]; then
          RUNOCC config:system:set trusted_domains 2 --value "$LANIP"
        fi
        # 127.0.0.1: appended at the next free index (never clobbers user
        # entries like a tailscale domain at index 3) if not present yet
        if ! RUNOCC config:system:get trusted_domains \
             | grep -qx '127.0.0.1'; then
          IDX="$(RUNOCC config:system:get trusted_domains | grep -c . || echo 0)"
          RUNOCC config:system:set trusted_domains "$IDX" --value 127.0.0.1
        fi
        RUNOCC config:system:set maintenance_window_start --type integer --value 2

        # --- tidy up indexes the install may skip ---
        # during a NC major upgrade window (needsDbUpgrade) db-occ commands
        # are refused — that is expected and cleared by `occ upgrade`
        RUNOCC db:add-missing-indices 2>/dev/null \
          || echo "  (db:add-missing-indices postponed — db pending occ upgrade)"

        RUNOCC status
        echo "nextcloud-init: done"
      '';

      # ------------------------------------------------------------------
      # user-facing commands
      # ------------------------------------------------------------------

      occ = pkgs.writeShellScriptBin "nextcloud-occ" ''
        # pass through password env vars for user:add/user:resetpassword
        exec /usr/bin/sudo -u ${ncUser} env \
          HOME=${ncRoot} \
          NEXTCLOUD_CONFIG_DIR=${ncConfig} \
          OC_PASS="''${OC_PASS:-}" \
          NC_PASS="''${NC_PASS:-}" \
          ${phpEnv}/bin/php ${nc}/occ "$@"
      '';

      # standalone config re-applier — pure php (no occ boot), so it works
      # even when config.php pins a stale apps_paths (post-major-swap rescue)
      applyConfigTool = pkgs.writeShellScriptBin "nextcloud-apply-config" ''
        exec /usr/bin/sudo -u ${ncUser} env \
          HOME=${ncRoot} \
          NEXTCLOUD_CONFIG_DIR=${ncConfig} \
          ${phpEnv}/bin/php ${applyConfig} "$@"
      '';

      deploy = pkgs.writeShellScriptBin "nextcloud-deploy" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        if [ "$(id -u)" -ne 0 ]; then
          echo "nextcloud-deploy: needs root, re-running with sudo..."
          exec sudo "$0" "$@"
        fi

        echo "== system users =="
        ensure_group() { getent group "$1" >/dev/null || groupadd --system "$1"; }
        ensure_user()  {
          getent passwd "$1" >/dev/null || \
            useradd --system --gid "$1" --home-dir "$2" --no-create-home --shell /usr/sbin/nologin "$1"
        }
        ensure_group ${ncUser}
        ensure_user ${ncUser} ${ncRoot}
        ensure_group ${webUser}
        ensure_user ${webUser} /var/lib/${webUser}
        id -nG ${webUser} | grep -wq ${ncUser} || usermod -aG ${ncUser} ${webUser}

        echo "== installing unit files =="
        install -m 0644 ${dbUnit}        ${unitDir}/nextcloud-db.service
        install -m 0644 ${fpmUnit}       ${unitDir}/nextcloud-fpm.service
        install -m 0644 ${caddyUnit}     ${unitDir}/nextcloud-caddy.service
        install -m 0644 ${initUnit}      ${unitDir}/nextcloud-init.service
        install -m 0644 ${cronUnit}      ${unitDir}/nextcloud-cron.service
        install -m 0644 ${cronTimer}     ${unitDir}/nextcloud-cron.timer
        install -m 0644 ${backupService} ${unitDir}/nextcloud-backup.service
        install -m 0644 ${backupTimer}   ${unitDir}/nextcloud-backup.timer
        install -m 0644 ${snapshotService} ${unitDir}/nextcloud-snapshot.service
        install -m 0644 ${snapshotTimer} ${unitDir}/nextcloud-snapshot.timer
        install -m 0644 ${dataSyncService} ${unitDir}/nextcloud-data-sync.service
        install -m 0644 ${dataSyncTimer} ${unitDir}/nextcloud-data-sync.timer
        install -m 0644 ${provisionService} ${unitDir}/nextcloud-provision.service
        install -m 0644 ${archiveBindMountUnit} ${unitDir}/var-lib-nextcloud-data-archive-files-Archive.mount

        echo "== backup roots =="
        install -d -o ${ncUser} -g ${ncUser} -m 0700 \
          ${backupRoot} ${resticRepo} ${stashRoot}
        # Nix bakes dataSyncTarget at eval time — shellcheck sees literals
        # where these guard the "disabled" knob (empty string).
        # shellcheck disable=SC2157
        if [ -n "${dataSyncTarget}" ]; then
          install -d -o ${ncUser} -g ${ncUser} -m 0700 ${dataSyncTarget}
        fi

        systemctl daemon-reload
        echo "== enabling services =="
        systemctl enable --now \
          var-lib-nextcloud-data-archive-files-Archive.mount \
          nextcloud-db.service \
          nextcloud-fpm.service \
          nextcloud-caddy.service \
          nextcloud-init.service \
          nextcloud-backup.timer \
          nextcloud-snapshot.timer \
          nextcloud-cron.timer
        # shellcheck disable=SC2157
        if [ -n "${dataSyncTarget}" ]; then
          systemctl enable --now nextcloud-data-sync.timer
        fi

        echo "== restarting to pick up the current build =="
        systemctl restart nextcloud-db.service
        systemctl restart nextcloud-fpm.service
        systemctl restart nextcloud-caddy.service
        systemctl restart nextcloud-init.service
        systemctl restart nextcloud-backup.timer nextcloud-snapshot.timer
        # shellcheck disable=SC2157
        if [ -n "${dataSyncTarget}" ]; then
          systemctl restart nextcloud-data-sync.timer
        fi
        systemctl restart nextcloud-provision.service

        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
          if ! ufw status | grep -q "${webPort}/tcp"; then
            ufw allow ${webPort}/tcp comment 'nextcloud (nix)'
            echo "== ufw: opened ${webPort}/tcp for nextcloud"
          fi
        fi

        echo
        echo "== stack status =="
        for u in nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init \
                 nextcloud-cron.timer nextcloud-backup.timer nextcloud-snapshot.timer \
                 nextcloud-data-sync.timer; do
          printf "  %-28s %s\n" "$u" "$(systemctl is-active "$u")"
        done
        echo
        echo "Nextcloud:    http://localhost:${webPort}/   (LAN: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${webPort}/ — change the port in flake.nix: webPort)"
        echo "Tailnet:      https://<node>.ts.net  (fronted by tailscale — see README 'Tailscale HTTPS')"
        echo "occ CLI:      nix run .#occ -- status"
        echo "Admin login:  admin / $(cat ${ncRoot}/admin-password 2>/dev/null || echo '(see /var/lib/nextcloud/admin-password)')"
      '';
      # ------------------------------------------------------------------
      # restic backup of the instance: pg_dump + file data in every archive
      # Modes: full | incremental | prune | check | list
      # ------------------------------------------------------------------
      ncBackupJob = pkgs.writeShellScriptBin "nc-backup" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        MODE="''${1:-}"
        case "$MODE" in
          full|incremental|prune|check|list|validate|validate-deep) ;;
          *) echo "usage: nc-backup [full|incremental|prune|check|list|validate|validate-deep]" >&2; exit 64 ;;
        esac

        # Repo + password file are owned by the nextcloud user: run as that
        # user regardless of the invoker (systemd already does).
        ME="$(id -un)"
        if [ "$ME" != "${ncUser}" ]; then
          if [ "$(id -u)" = "0" ]; then
            exec ${pkgs.util-linux}/bin/runuser -u ${ncUser} -- "$0" "$@"
          else
            exec sudo -u ${ncUser} env HOME=${ncRoot} "$0" "$@"
          fi
        fi

        export HOME=${ncRoot}
        export NEXTCLOUD_CONFIG_DIR=${ncConfig}
        export XDG_CACHE_HOME=${ncRoot}/cache
        export RESTIC_REPOSITORY=${resticRepo}
        export RESTIC_PASSWORD_FILE=${passFile}

        OCC() { ${phpEnv}/bin/php ${nc}/occ "$@"; }

        mkdir -p "${backupRoot}" "${resticRepo}" "${stashRoot}"
        chmod 0700 "${backupRoot}" "${stashRoot}"
        if [ ! -s "${passFile}" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${passFile}"
          chmod 0600 "${passFile}"
          echo "nc-backup: generated restic password file ${passFile}"
        fi
        if [ ! -e "${resticRepo}/config" ]; then
          echo "nc-backup: initialising restic repository at ${resticRepo}"
          ${restic}/bin/restic init
        fi

        case "$MODE" in
          list)
            ${restic}/bin/restic snapshots --compact
            echo
            echo "repo dedup size (all snapshots):"
            ${restic}/bin/restic stats --mode raw-data || true
            exit 0
            ;;
          validate|validate-deep)
            TMP="$(mktemp -d)"
            trap 'rm -rf "''$TMP"' EXIT
            echo "nc-backup: extracting latest db dump from repo"
            ${restic}/bin/restic restore latest --target "$TMP" \
              --include "${stashRelDump}"
            DUMP="$TMP${stashRoot}/nextcloud.dump"
            [ -s "$DUMP" ] || { echo "nc-backup: latest archive has no db dump" >&2; exit 1; }
            echo "nc-backup: dump size: $(du -h "$DUMP" | cut -f1)"
            echo "nc-backup: validating TOC (pg_restore --list)"
            ${pg}/bin/pg_restore --list "$DUMP" >> "$TMP/toc.txt"
            if [ ! -s "$TMP/toc.txt" ]; then
              echo "nc-backup: FAILED — dump TOC is unreadable" >&2
              exit 1
            fi
            echo "nc-backup: TOC ok — $(wc -l < "$TMP/toc.txt") entries, $(grep -c 'TABLE DATA' "$TMP/toc.txt" || echo 0) table-data sections"
            if [ "$MODE" != "validate-deep" ]; then
              echo "nc-backup: validate (fast) OK"
              exit 0
            fi
            echo "nc-backup: deep validation — full pg_restore into scratch db"
            SCR="nc_verify_$(date +%s)"
            ${pg}/bin/createdb -h ${dbSock} -U ${ncUser} "$SCR"
            if ! ${pg}/bin/pg_restore --host=${dbSock} --username=${ncUser} \
                 --dbname="$SCR" --jobs=2 "$DUMP"; then
              echo "nc-backup: FAILED — dump does not fully restore" >&2
              ${pg}/bin/dropdb -h ${dbSock} -U ${ncUser} "$SCR" || true
              exit 1
            fi
            echo "nc-backup: deep restore OK (scratch db populated)"
            ${pg}/bin/dropdb -h ${dbSock} -U ${ncUser} "$SCR"
            echo "nc-backup: validate (deep) OK"
            exit 0
            ;;
          check) exec ${restic}/bin/restic check ;;
          prune)
            echo "nc-backup: applying retention policy (forget --prune)"
            exec ${restic}/bin/restic forget --prune \
              --keep-hourly ${keepHourly} --keep-daily ${keepDaily} \
              --keep-weekly ${keepWeekly} --keep-monthly ${keepMonthly}
            ;;
        esac

        MAINT_OFF() {
          ${phpEnv}/bin/php ${nc}/occ maintenance:mode --off >/dev/null 2>&1 || true
        }

        echo "nc-backup: pg_dump -> ${stashRoot}/nextcloud.dump"
        rm -f "${stashRoot}/nextcloud.dump"
        ${pg}/bin/pg_dump --format=custom \
          --host=${dbSock} --username=${ncUser} \
          --file=${stashRoot}/nextcloud.dump nextcloud
        [ -s "${stashRoot}/nextcloud.dump" ] || {
          echo "nc-backup: pg_dump produced nothing" >&2; exit 1;
        }

        if [ "$MODE" = "full" ]; then
          echo "nc-backup: maintenance:mode ON (consistent full snapshot)"
          OCC maintenance:mode --on
          trap MAINT_OFF EXIT
        fi

        # Scope: db dump + app state (config/, store-apps/, admin-password).
        # The user-file tree (data/) is deliberately NOT archived — it will
        # live behind a separate directory-sync job (see README).
        ${restic}/bin/restic backup \
          --tag nextcloud --tag "$MODE" \
          --exclude "${ncRoot}/cache" \
          --exclude "${ncRoot}/data" \
          --exclude "${ncRoot}/php-slow.log" \
          --exclude "${ncRoot}/.data-sync.lock" \
          --exclude "${ncRoot}/.psql_history" \
          "${ncRoot}" "${stashRoot}"

        if [ "$MODE" = "full" ]; then
          echo "nc-backup: applying retention policy"
          ${restic}/bin/restic forget --prune \
            --keep-hourly ${keepHourly} --keep-daily ${keepDaily} \
            --keep-weekly ${keepWeekly} --keep-monthly ${keepMonthly}
          OCC maintenance:mode --off
          trap - EXIT
        fi

        rm -f "${stashRoot}/nextcloud.dump"
        echo "nc-backup: done ($MODE)"
      '';

      # Root-facing restore: one archive = db + files. The current state dir
      # is moved aside (never deleted) so a mistake is undoable.
      ncRestoreJob = pkgs.writeShellScriptBin "nc-restore" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        if [ "$(id -u)" -ne 0 ]; then
          echo "nc-restore: needs root, re-running with sudo..."
          exec sudo CONFIRM="''${CONFIRM:-}" FORCE="''${FORCE:-}" "$0" "$@"
        fi

        SNAP="''${1:-latest}"
        echo "⚠  This overwrites the CURRENT instance (db + files) with archive: $SNAP"
        echo "   Current /var/lib/nextcloud is moved aside (kept, not deleted)."
        if [ "''${FORCE:-0}" != "1" ]; then
          printf 'Type RESTORE to continue: '
          read -r ans
          [ "$ans" = "RESTORE" ] || { echo "aborted"; exit 1; }
        fi

        TS="$(date +%Y%m%d-%H%M%S)"
        EXTRACT="${backupRoot}/restore-staging-$TS"
        PREV="/var/lib/nextcloud.pre-restore-$TS"

        echo "== stopping nextcloud services =="
        systemctl stop nextcloud-fpm nextcloud-caddy \
          nextcloud-cron.timer nextcloud-cron.service nextcloud-init 2>/dev/null || true

        mkdir -p "$EXTRACT"
        echo "== extracting archive -> $EXTRACT =="
        env RESTIC_REPOSITORY=${resticRepo} RESTIC_PASSWORD_FILE=${passFile} \
          ${restic}/bin/restic restore "$SNAP" --target "$EXTRACT"

        SRCNC="$EXTRACT/var/lib/nextcloud"
        DUMP="$EXTRACT${stashRoot}/nextcloud.dump"
        [ -d "$SRCNC/config" ] || { echo "nc-restore: archive has no config/ dir" >&2; exit 1; }
        [ -s "$DUMP" ] || { echo "nc-restore: archive has no db dump at $DUMP" >&2; exit 1; }

        RU() { ${pkgs.util-linux}/bin/runuser -u ${ncUser} -- "$@"; }
        PSQL() { RU ${pg}/bin/psql -h ${dbSock} -U ${ncUser} -d postgres "$@"; }

        echo "== db: drop + recreate =="
        PSQL -c "DROP DATABASE IF EXISTS nextcloud WITH (FORCE)"
        RU ${pg}/bin/createdb -h ${dbSock} -U ${ncUser} nextcloud

        echo "== db: recreate app role from archived config.php =="
        readarray -t CRED < <(${phpEnv}/bin/php -r \
          'include $argv[1]; echo $CONFIG["dbuser"], "\n", $CONFIG["dbpassword"];' \
          "$SRCNC/config/config.php")
        DBU="''${CRED[0]}"
        DBP="''${CRED[1]}"
        [ -n "$DBU" ] || { echo "nc-restore: could not read dbuser from config.php" >&2; exit 1; }
        if PSQL -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DBU'" | grep -q 1; then
          PSQL -c "ALTER ROLE \"$DBU\" PASSWORD '$DBP'"
        else
          PSQL -c "CREATE USER \"$DBU\" CREATEDB PASSWORD '$DBP'"
        fi

        echo "== db: pg_restore =="
        RU ${pg}/bin/pg_restore --host=${dbSock} --username=${ncUser} \
          --dbname=nextcloud --jobs=2 "$DUMP"

        echo "== files =="
        if [ -d "$SRCNC/data" ]; then
          echo "nc-restore: archive includes user data (data/) — full restore"
          [ -e "/var/lib/nextcloud" ] && mv /var/lib/nextcloud "$PREV"
          install -d -o ${ncUser} -g ${ncUser} /var/lib/nextcloud
          ${pkgs.rsync}/bin/rsync -a "$SRCNC/" /var/lib/nextcloud/
        else
          echo "nc-restore: state-only archive — existing data/ (user files) left untouched"
          [ -e "${ncRoot}/config" ] && mv "${ncRoot}/config" "${ncRoot}/config.pre-restore-$TS"
          [ -e "${ncRoot}/store-apps" ] && mv "${ncRoot}/store-apps" "${ncRoot}/store-apps.pre-restore-$TS"
          ${pkgs.rsync}/bin/rsync -a "$SRCNC/" /var/lib/nextcloud/
        fi
        chown -R ${ncUser}:${ncUser} /var/lib/nextcloud

        echo "== restarting services =="
        systemctl start nextcloud-fpm nextcloud-caddy
        # full archives snapshot config.php while maintenance mode is ON
        # (the consistency window) — a restored instance must never boot
        # stuck in maintenance
        runuser -u ${ncUser} -- env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} \
          ${phpEnv}/bin/php ${nc}/occ maintenance:mode --off >/dev/null 2>&1 || true
        systemctl restart nextcloud-init.service
        systemctl start nextcloud-cron.timer

        echo "== verify =="
        RU env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} \
          ${phpEnv}/bin/php ${nc}/occ status | sed -n '1,8p'
        rm -rf "$EXTRACT"

        echo
        echo "== done: restored archive $SNAP =="
        if [ -d "$PREV" ]; then
          echo "== previous full state kept at $PREV (delete manually once happy) =="
        else
          echo "== previous config/store-apps kept at *.pre-restore-$TS (data/ untouched) =="
        fi
      '';

      # ------------------------------------------------------------------
      # User-data directory mirror (rsync, deletion-safe via .trash/<date>)
      # ------------------------------------------------------------------
      ncDataSyncJob = pkgs.writeShellScriptBin "nc-data-sync" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        MODE="''${1:-sync}"
        case "$MODE" in sync|status|compare-quick|compare-deep) ;;
          *) echo "usage: nc-data-sync [sync|status|compare-quick|compare-deep]" >&2; exit 64 ;;
        esac

        # Nix bakes dataSyncTarget at eval time — shellcheck sees a literal
        # where this guards the "disabled" knob (empty string).
        # shellcheck disable=SC2157
        if [ -z "${dataSyncTarget}" ]; then
          echo "data-sync: dataSyncTarget not configured — nothing to do"
          exit 0
        fi

        # status needs journal + root-readable dirs: prefer root.
        # everything else must run as nextcloud (file ownership consistency).
        ME="$(id -un)"
        if [ "$MODE" = "status" ]; then
          if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi
        elif [ "$ME" != "${ncUser}" ]; then
          if [ "$(id -u)" = "0" ]; then
            exec ${pkgs.util-linux}/bin/runuser -u ${ncUser} -- "$0" "$@"
          else
            exec sudo -u ${ncUser} env HOME=${ncRoot} "$0" "$@"
          fi
        fi
        export HOME=${ncRoot}

        EXCLUDES=(--exclude '/nextcloud.log' --exclude '/appdata_*/preview')
        CNT() {
          ${pkgs.findutils}/bin/find "$1" -type f \
            ! -path '*/appdata_*/preview/*' ! -name 'nextcloud.log' \
            ! -path '*/.trash/*' | wc -l
        }

        case "$MODE" in
          status)
            echo "== user-data mirror =="
            echo "target: ${dataSyncTarget}"
            du -sh "${ncRoot}/data" 2>/dev/null | sed 's/^/  live  : /' || true
            du -sh "${dataSyncTarget}" 2>/dev/null | sed 's/^/  mirror: /' || true
            echo "files (excl. caches): live $(CNT "${ncRoot}/data") / mirror $(CNT "${dataSyncTarget}")"
            if [ -d "${dataSyncTarget}/.trash" ]; then
              echo "preserved deletions: $(du -sh "${dataSyncTarget}/.trash" 2>/dev/null | cut -f1) across $(find "${dataSyncTarget}/.trash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) day-dirs"
            else
              echo "preserved deletions: none"
            fi
            echo "== last syncs (journal) =="
            journalctl -u nextcloud-data-sync -q --no-pager -n 400 2>/dev/null \
              | grep -F 'mirrored to' | tail -3 || true
            systemctl list-timers nextcloud-data-sync.timer --no-pager 2>/dev/null | sed -n '2p' || true
            exit 0
            ;;
          compare-quick)
            echo "== quick compare (regenerable caches excluded from counting) =="
            echo "live files  : $(CNT "${ncRoot}/data")"
            echo "mirror files: $(CNT "${dataSyncTarget}")"
            echo "sizes (informative only — caches/trash skew them):"
            du -sh "${ncRoot}/data" 2>/dev/null | sed 's/^/  live  : /' || true
            du -sh "${dataSyncTarget}" 2>/dev/null | sed 's/^/  mirror: /' || true
            echo "hint: mismatch? run: nix run .#nc-data-sync -- compare-deep"
            exit 0
            ;;
          compare-deep)
            echo "== deep compare: rsync --dry-run --itemize-changes =="
            set +e
            RS_OUT="$(${pkgs.rsync}/bin/rsync -a -n --itemize-changes --delete \
              "''${EXCLUDES[@]}" --exclude '/.trash' \
              ${ncRoot}/data/ ${dataSyncTarget}/ 2>&1)"
            set -e
            COUNT="$(printf '%s\n' "$RS_OUT" | grep -cE '^([<c>][fs.]|\*deleting)' || true)"
            if [ "$COUNT" = 0 ]; then
              echo "in perfect sync"
            else
              printf '%s\n' "$RS_OUT" | sed -n '1,150p'
              echo "... $(printf '%s\n' "$RS_OUT" | wc -l) entries total — mirror is out of date (run nc-data-sync sync)"
              exit 1
            fi
            exit 0
            ;;
        esac

        # ---- sync ----
        [ -d "${dataSyncTarget}" ] || { echo "data-sync: target ${dataSyncTarget} missing (deploy should have created it)" >&2; exit 1; }

        DELS="${dataSyncTarget}/.trash/$(date +%F)"

        set +e
        ${pkgs.util-linux}/bin/flock -n -E 3 "${ncRoot}/.data-sync.lock" \
          ${pkgs.rsync}/bin/rsync \
            -a \
            --delete \
            --backup --backup-dir="$DELS/" \
            --exclude '/.trash' \
            "''${EXCLUDES[@]}" \
            ${ncRoot}/data/ ${dataSyncTarget}/
        rc=$?
        set -e
        if [ "$rc" = 3 ]; then
          echo "data-sync: previous sync still running — skipped"
          exit 0
        fi
        if [ "$rc" != 0 ]; then
          echo "data-sync: rsync failed (rc=$rc)" >&2
          exit "$rc"
        fi

        # age out preserved deletions
        if [ -d "${dataSyncTarget}/.trash" ]; then
          ${pkgs.findutils}/bin/find "${dataSyncTarget}/.trash" \
            -mindepth 1 -maxdepth 1 -type d -mtime +${dataSyncTrashDays} \
            -exec rm -rf {} + 2>/dev/null || true
        fi

        echo "data-sync: ${ncRoot}/data mirrored to ${dataSyncTarget} (deletions kept in .trash for ${dataSyncTrashDays} days)"
      '';

      # ------------------------------------------------------------------
      # systemd backup units
      # ------------------------------------------------------------------
      backupService = pkgs.writeText "nextcloud-backup.service" ''
        [Unit]
        Description=Nextcloud FULL backup — db dump + app state via restic (Nix-managed)
        After=nextcloud-db.service nextcloud-init.service
        Requires=nextcloud-db.service

        [Service]
        Type=oneshot
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncBackupJob}/bin/nc-backup full
        TimeoutStartSec=4h
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${backupRoot}
        RestrictAddressFamilies=AF_UNIX
      '';

      backupTimer = pkgs.writeText "nextcloud-backup.timer" ''
        [Unit]
        Description=Full Nextcloud backup daily at 03:00 (Nix-managed)

        [Timer]
        OnCalendar=*-*-* 03:00:00
        RandomizedDelaySec=10m
        Persistent=true

        [Install]
        WantedBy=timers.target
      '';

      snapshotService = pkgs.writeText "nextcloud-snapshot.service" ''
        [Unit]
        Description=Nextcloud hourly snapshot — db dump + app state via restic (Nix-managed)
        After=nextcloud-db.service
        Requires=nextcloud-db.service

        [Service]
        Type=oneshot
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncBackupJob}/bin/nc-backup incremental
        TimeoutStartSec=2h
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${backupRoot}
        RestrictAddressFamilies=AF_UNIX
      '';

      snapshotTimer = pkgs.writeText "nextcloud-snapshot.timer" ''
        [Unit]
        Description=Hourly Nextcloud snapshot (Nix-managed)

        [Timer]
        OnCalendar=hourly
        RandomizedDelaySec=5m
        Persistent=true

        [Install]
        WantedBy=timers.target
      '';

      # ------------------------------------------------------------------
      # ZFS pools + replication (phase interlocks enforced via stamps)
      # ------------------------------------------------------------------

      zfsCreatePrimary = pkgs.writeShellScriptBin "zfs-create-primary" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        # sudo env_reset strips PATH and the nix feature flags the tail needs
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
        export NIX_CONFIG="experimental-features = nix-command flakes"
        [ "''${CONFIRM:-}" = "primary" ] \
          || { echo "This DESTROYS ${primaryDisk} (sdc1 NTFS). The verified second copy is the disaster mirror." >&2
               echo "Set CONFIRM=primary to proceed." >&2; exit 1; }
        # interlock: the verified disaster mirror (root disk) is the one
        # second copy of the sdc1 content — the NTFS phase-1 mirror was
        # dropped from the plan (legacy sdb1 content is Phase-3-dropped)
        HAVE_DISASTER=0; ARCHIVE_SRC=""
        [ -f ${migrationState}/disaster-mirror-verified ] && HAVE_DISASTER=1 || true
        if [ -d "${disasterMirror}" ] && [ -n "$(find ${disasterMirror} -type f 2>/dev/null | head -1)" ]; then
          ARCHIVE_SRC="${disasterMirror}"
          echo "interlock: local disaster mirror present ($(find ${disasterMirror} -type f | wc -l) files)"
        fi
        if [ "$HAVE_DISASTER" = 0 ] || [ -z "$ARCHIVE_SRC" ]; then
          echo "refusing: no verified second copy of the sdc1 content found" >&2
          echo "(need the verified ${disasterMirror})" >&2
          exit 1
        fi
        # device triple-check
        test -b "${primaryDisk}" || { echo "no such device: ${primaryDisk} — reconnect sdc1" >&2; exit 1; }
        # nix bakes model/minsize at eval time; sandbox runs skip identity checks
        # shellcheck disable=SC2157
        if [ -n "${primaryDiskModel}" ]; then
          # partition nodes carry no MODEL — read identity off the parent
          # disk (pattern proven on the real drive by the disaster recipe)
          PARENT="$(lsblk -no PKNAME "${primaryDisk}" | tail -1)"; PARENT="/dev/$PARENT"
          MODEL="$(lsblk -d -no MODEL "$PARENT")"
          case "$MODEL" in *"${primaryDiskModel}"*) ;; *) echo "refusing: wrong drive for ${primaryDisk} (model '$MODEL', expected ${primaryDiskModel})" >&2; exit 1;; esac
          SZ="$(lsblk -d -b -no SIZE "$PARENT")"
          if [ -n "${primaryDiskMinSize}" ]; then
            [ "$SZ" -ge "${primaryDiskMinSize}" ] || { echo "size mismatch ($SZ on $PARENT)" >&2; exit 1; }
          fi
        fi
        findmnt "${primaryDisk}" >/dev/null 2>&1 \
          && { echo "refusing: ${primaryDisk} is mounted" >&2; exit 1; }
        # resumable: an interrupted run leaves the pool (and the datadir on
        # it) in place — skip creation, heal the mounts, resume the import
        RESUME=0
        if zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolPrimary}; then
          RESUME=1
          echo "primary: pool exists — resuming phase 2 (no recreation)"
          zpool clear ${zfsPoolPrimary} 2>/dev/null || zpool clear -F ${zfsPoolPrimary} 2>/dev/null || true
          zfs mount -a 2>/dev/null || true
          findmnt -no SOURCE /var/lib/nextcloud/data | grep -q "${zfsPoolPrimary}/nextcloud" \
            || { echo "datadir is not ${zfsPoolPrimary}/nextcloud — cannot resume safely" >&2; exit 1; }
          zfs list -H -o name ${zfsPoolPrimary}/archive >/dev/null 2>&1 \
            || { echo "${zfsPoolPrimary}/archive missing — cannot resume safely" >&2; exit 1; }
        fi
        if [ "$RESUME" = 1 ]; then
          echo "primary: datadir already on zfs — skipping creation/restore"
        else
          if [ -f ${migrationState}/phase2-complete ]; then
            echo "refusing: phase-2 already stamped but pool missing — needs manual recovery" >&2
            exit 1
          fi
          # maintenance + pause timers + preserve the current datadir
          nix run .#occ -- maintenance:mode --on >/dev/null 2>&1 || true
          nix run .#apply-config >/dev/null 2>&1 || true
          systemctl stop nextcloud-fpm nextcloud-caddy nextcloud-init \
            nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-data-sync.timer \
            nextcloud-provision.service nextcloud-cron.timer 2>/dev/null || true
          SAVED="${backupRoot}/pre-zfs-datadir-$(date +%Y%m%d-%H%M%S).tar.gz"
          tar czf "$SAVED" -C /var/lib/nextcloud data
          echo "primary: datadir safety tar at $SAVED"
          mv /var/lib/nextcloud/data /var/lib/nextcloud/data.pre-zfs
          mkdir -p /var/lib/nextcloud/data
          echo "primary: creating zpool (DESTROYS ${primaryDisk} NTFS content)"
          zpool create -f -o ashift=12 -O compression=lz4 -O xattr=sa \
            -O acltype=posixacl -O atime=off ${zfsPoolPrimary} "${primaryDisk}"
          zfs create -o mountpoint=/var/lib/nextcloud/data ${zfsPoolPrimary}/nextcloud
          zfs create -o mountpoint=/mnt/archive ${zfsPoolPrimary}/archive
          echo "primary: restoring nc datadir from the safety tar"
          tar xzf "$SAVED" -C /var/lib/nextcloud
        fi
        chown -R nextcloud:nextcloud /var/lib/nextcloud/data
        echo "primary: importing personal content from $ARCHIVE_SRC -> /mnt/archive"
        rsync -aH --numeric-ids --info=progress2 \
          "$ARCHIVE_SRC"/ /mnt/archive/
        FS="$(find "$ARCHIVE_SRC" -type f | wc -l)"
        FA="$(find /mnt/archive -type f | wc -l)"
        echo "primary: archive files secondcopy=$FS imported=$FA"
        systemctl start nextcloud-fpm nextcloud-caddy nextcloud-init.service 2>/dev/null || true
        nix run .#occ -- maintenance:mode --off >/dev/null 2>&1 || true
        nix run .#occ -- status | grep -q 'installed: true' \
          || { echo "nextcloud not healthy after migration" >&2; exit 1; }
        install -d -m 0755 ${migrationState}
        touch ${migrationState}/phase2-complete
        echo "primary: phase-2 complete — NC is live on the zfs datadir; personal archive at /mnt/archive"
      '';

      zfsCreateBackup = pkgs.writeShellScriptBin "zfs-create-backup" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        test -f ${migrationState}/phase2-complete \
          || { echo "refusing: phase-2 stamp missing (run zfs-create-primary first)" >&2; exit 1; }
        [ "''${CONFIRM:-}" = "backup" ] \
          || { echo "This DESTROYS ${backupDisk} (sdb1 NTFS mirror). The primary zfs datasets are the verified copies now." >&2
               echo "Set CONFIRM=backup to proceed." >&2; exit 1; }
        test -b "${backupDisk}" || { echo "no such device: ${backupDisk} — reconnect sdb1" >&2; exit 1; }
        if findmnt -S "${backupDisk}" >/dev/null 2>&1; then
          echo "refusing: ${backupDisk} is mounted" >&2; exit 1
        fi
        zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolBackup} \
          && { echo "pool 'backup' already exists" >&2; exit 1; }
        echo "backup: creating zpool (DESTROYS ${backupDisk} NTFS mirror copy)"
        zpool create -f -o ashift=12 -O compression=on -O xattr=sa \
          -O acltype=posixacl -O atime=off \
          -O mountpoint=${replicaMount} ${zfsPoolBackup} "${backupDisk}"
        TS="$(date +%Y%m%d%H%M%S)"
        zfs snapshot -r ${zfsPoolPrimary}@seed-$TS
        echo "backup: seeding replica via zfs send/receive"
        # -o mountpoint keeps the replica out of the primary's mountpoints
        # (sent properties would otherwise aim it at the live datadir/archive)
        zfs send -R ${zfsPoolPrimary}/nextcloud@seed-$TS \
          | zfs receive -F -o mountpoint=${replicaMount}/nextcloud-data ${replicaDataset}
        zfs send -R ${zfsPoolPrimary}/archive@seed-$TS \
          | zfs receive -F -o mountpoint=${replicaMount}/archive ${zfsPoolBackup}/archive
        FB="$(find ${replicaMount}/nextcloud-data -type f 2>/dev/null | wc -l)"
        FA="$(find ${replicaMount}/archive -type f 2>/dev/null | wc -l)"
        echo "backup: replica files: nextcloud-data=$FB archive=$FA"
        touch ${migrationState}/phase3-complete
        echo "backup: phase-3 complete — replica seeded on the backup drive"
      '';

      zfsReplicate = pkgs.writeShellScriptBin "zfs-replicate" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolPrimary} \
          || { echo "primary pool missing" >&2; exit 1; }
        zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolBackup} \
          || { echo "backup pool missing" >&2; exit 1; }
        STAMP="sync-$(date +%Y%m%d%H%M%S)"
        # manual + timer runs can land in the same second — never collide
        while zfs list -H -o name "${zfsPoolPrimary}/nextcloud@$STAMP" >/dev/null 2>&1; do
          sleep 1
          STAMP="sync-$(date +%Y%m%d%H%M%S)"
        done
        PREV_NC="$(zfs list -t snapshot -o name -H -s creation ${zfsPoolPrimary}/nextcloud | tail -1 | cut -d@ -f2 || true)"
        PREV_AR="$(zfs list -t snapshot -o name -H -s creation ${zfsPoolPrimary}/archive | tail -1 | cut -d@ -f2 || true)"
        zfs snapshot ${zfsPoolPrimary}/nextcloud@$STAMP
        zfs snapshot ${zfsPoolPrimary}/archive@$STAMP
        if [ -n "$PREV_NC" ]; then
          zfs send -I ${zfsPoolPrimary}/nextcloud@$PREV_NC ${zfsPoolPrimary}/nextcloud@$STAMP \
            | zfs receive -F -x mountpoint ${replicaDataset}
        else
          zfs send -R ${zfsPoolPrimary}/nextcloud@$STAMP | zfs receive -F -x mountpoint ${replicaDataset}
        fi
        if [ -n "$PREV_AR" ]; then
          zfs send -I ${zfsPoolPrimary}/archive@$PREV_AR ${zfsPoolPrimary}/archive@$STAMP \
            | zfs receive -F -x mountpoint ${zfsPoolBackup}/archive
        else
          zfs send -R ${zfsPoolPrimary}/archive@$STAMP | zfs receive -F -x mountpoint ${zfsPoolBackup}/archive
        fi
        date -u +"%Y-%m-%dT%H:%M:%SZ snap=$STAMP" > ${primaryMount}.last-replication
        KEEP=$(( ${zfsKeepSnapshots} ))
        # retention is SPACE-DRIVEN: history persists while a pool has room;
        # below its free-space floor the oldest sync snapshots are destroyed,
        # never the newest $KEEP (those carry the replication bases)
        prune_oldest() { # <pool> <minFreeBytes> <dataset>
          local POOL="$1" MINFREE="$2" DS="$3" AVAIL
          AVAIL="$(zfs get -Hp -o value avail "$POOL")"
          if [ "$AVAIL" -ge "$MINFREE" ]; then return 0; fi
          echo "replicate: $POOL below free-space floor ($AVAIL < $MINFREE) — pruning oldest snapshots on $DS"
          zfs list -t snapshot -o name -H -s creation "$DS" 2>/dev/null \
            | grep -aF '@sync' | head -n -$KEEP | cut -d@ -f2 \
            | sort -u | while IFS= read -r s; do
                zfs destroy "$DS@$s" 2>/dev/null || true
              done
        }
        prune_oldest ${zfsPoolPrimary} ${primaryPruneMinFree} ${zfsPoolPrimary}/nextcloud
        prune_oldest ${zfsPoolPrimary} ${primaryPruneMinFree} ${zfsPoolPrimary}/archive
        prune_oldest ${zfsPoolBackup} ${replicaPruneMinFree} ${zfsPoolBackup}/nextcloud-data
        prune_oldest ${zfsPoolBackup} ${replicaPruneMinFree} ${zfsPoolBackup}/archive
        echo "replicate: done (snap $STAMP; retention: keep $KEEP, prune only below free-space floors)"
      '';

      zfsVerifyMigration = pkgs.writeShellScriptBin "zfs-verify-migration" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        test -f ${migrationState}/phase3-complete \
          || { echo "refusing: phase-3 stamp missing (run zfs-create-backup first)" >&2; exit 1; }
        zpool status ${zfsPoolPrimary} 2>/dev/null | grep -q ONLINE \
          || { echo "primary not ONLINE" >&2; exit 1; }
        zpool status ${zfsPoolBackup} 2>/dev/null | grep -q ONLINE \
          || { echo "backup not ONLINE" >&2; exit 1; }
        findmnt -no SOURCE /var/lib/nextcloud/data \
          | grep -q primary || { echo "datadir not a zfs mount" >&2; exit 1; }
        systemctl is-active --quiet nextcloud-fpm nextcloud-db nextcloud-caddy \
          || { echo "stack not healthy" >&2; exit 1; }
        REP="$(find ${replicaMount} -type f 2>/dev/null | wc -l)"
        [ "$REP" -ge 1 ] || { echo "replica empty" >&2; exit 1; }
        touch ${migrationState}/migration-complete
        echo "migration verified — the disaster mirror stays as the second copy until the archive
        # import completes; removal stays manual and gated (CONFIRM=disaster)"
      '';

      zfsCheck = pkgs.writeShellScriptBin "zfs-check" ''
        set -euo pipefail
        echo "== zpool status =="
        zpool status -v 2>/dev/null | head -24 || true
        echo "== datasets =="
        zfs list 2>/dev/null || true
        echo "== snapshots (last 12) =="
        zfs list -t snapshot -o name,creation -s creation 2>/dev/null | tail -12 || true
        echo "== datadir mount =="
        findmnt -no TARGET,SOURCE,FSTYPE /var/lib/nextcloud/data 2>/dev/null || true
        echo "== last replication =="
        cat ${primaryMount}.last-replication 2>/dev/null || echo "(never)"
        echo "== migration state =="
        ls ${migrationState} 2>/dev/null || true
      '';

      ncProvisionJob = pkgs.writeShellScriptBin "nc-provision" ''
        set -euo pipefail
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        # run as the nextcloud user, like the other jobs
        ME="$(id -un)"
        if [ "$ME" != "${ncUser}" ]; then
          if [ "$(id -u)" = "0" ]; then
            exec ${pkgs.util-linux}/bin/runuser -u ${ncUser} -- \
              env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} "$0" "$@"
          else
            exec sudo -u ${ncUser} env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} "$0" "$@"
          fi
        fi
        export HOME=${ncRoot}
        export NEXTCLOUD_CONFIG_DIR=${ncConfig}

        SPECS=( ${provisionShellArray} )
        REMOVES=( ${removeShellArray} )
        if [ "''${#SPECS[@]}" -eq 0 ] && [ "''${#REMOVES[@]}" -eq 0 ]; then
          echo "provision: no users configured — nothing to do"
          exit 0
        fi

        OCC() { ${phpEnv}/bin/php ${nc}/occ "$@"; }
        CRED="${ncRoot}/provision-credentials-$(date +%Y%m%d-%H%M%S).log"
        touch "$CRED"
        chmod 0600 "$CRED"
        NEW=0

        for raw in "''${SPECS[@]}"; do
          # split on tabs WITHOUT read(): read treats tab as whitespace and
          # collapses runs of tabs, losing EMPTY middle fields (quota)
          mapfile -t F < <(printf '%s\n' "''${raw//''$'\t'/$'\n'}")
          uid="''${F[0]:-}"; display="''${F[1]:-}"
          quota="''${F[2]:-}"; groups="''${F[3]:-}"
          # removal wins: a uid listed in deprovisionedUsers is never
          # re-created by the provision loop (they would otherwise oscillate
          # create → delete on every deploy)
          SKIP=" ''${REMOVES[*]} "
          [[ "$SKIP" == *" $uid "* ]] && {
            echo "provision: skipping $uid — listed in deprovisionedUsers"
            continue
          }
          if OCC user:info "$uid" >/dev/null 2>&1; then
            echo "provision: $uid exists — applying desired quota/groups"
          else
            PW="$(${pkgs.openssl}/bin/openssl rand -hex 18)"
            export OC_PASS="$PW"
            if [ -n "$display" ]; then
              OCC user:add "$uid" --password-from-env --display-name "$display" >/dev/null
            else
              OCC user:add "$uid" --password-from-env >/dev/null
            fi
            unset OC_PASS
            printf 'uid=%s password=%s (created %s)\n' "$uid" "$PW" "$(date -u)" >> "$CRED"
            NEW=$((NEW + 1))
            echo "provision: created $uid — password appended to $CRED"
          fi
          [ -n "$quota" ] && OCC user:setting "$uid" files quota "$quota"
          if [ -n "$groups" ]; then
            IFS=';' read -ra GS <<< "$groups"
            for g in "''${GS[@]}"; do
              # occ prints success to stdout ("Created group …",
              # "user X added") — gate on EXIT STATUS, not output
              if ! OUT="$(OCC group:add "$g" 2>&1)"; then
                case "$OUT" in
                  *"already exists"*) : ;;
                  *) echo "provision: group:add $g FAILED: $OUT" >&2 ;;
                esac
              fi
              if ! OUT="$(OCC group:adduser "$g" "$uid" 2>&1)"; then
                case "$OUT" in
                  *"already in group"*|*"added"*) : ;;
                  *) echo "provision: group:adduser $g $uid FAILED: $OUT" >&2 ;;
                esac
              fi
            done
          fi
        done

        # --- explicit removals (deprovisionedUsers) ----------------------
        # backup-then-delete; the deletion is refused if the backup cannot
        # be verified. Idempotent: entries no-op once the user is gone.
        for raw in "''${REMOVES[@]}"; do
          ruid="$raw"
          UOK() { echo "$1" | grep -qE '^[A-Za-z0-9_.@-]+$'; }
          UOK "$ruid" || { echo "provision: refusing to remove suspicious uid '$ruid'" >&2; exit 1; }
          if ! OCC user:info "$ruid" >/dev/null 2>&1; then
            echo "provision: $ruid already absent — nothing to do"
            continue
          fi
          DEST="${backupRoot}/deprovisioned/$ruid/$(date +%Y%m%d-%H%M%S)"
          install -d -m 0700 "$DEST"
          echo "provision: removing $ruid — backup first (files + db dump) into $DEST"
          if [ -d "${ncRoot}/data/$ruid" ]; then
            # complete per-user home (files/, uploads/, trash, …)
            cp -a "${ncRoot}/data/$ruid" "$DEST/home"
          else
            echo "provision: (no data dir for $ruid)" | tee "$DEST/home-note.txt"
          fi
          ${pg}/bin/pg_dump --format=custom \
            --host=${dbSock} --username=${ncUser} \
            --file="$DEST/db.dump" nextcloud
          OCC user:info "$ruid" > "$DEST/user-info.txt" 2>&1 || true
          if [ ! -s "$DEST/db.dump" ]; then
            echo "provision: FATAL — backup unverified; NOT deleting $ruid" >&2
            exit 1
          fi
          OCC user:delete "$ruid" >/dev/null
          echo "removed uid=$ruid backup=$DEST (occ user:delete done)" \
            | tee -a "${ncRoot}/provision-removals.log"
        done
        chmod 0600 "$CRED"
        echo "provision: done ($NEW created, $(( ''${#SPECS[@]} - NEW )) already existed)"
      '';

      provisionService = pkgs.writeText "nextcloud-provision.service" ''
        [Unit]
        Description=Nextcloud declarative user provisioning (Nix-managed)
        # After-only: Requires would cascade-stop provision whenever init
        # restarts (deploy restarts both — double invocation)
        After=nextcloud-init.service

        [Service]
        Type=oneshot
        RemainAfterExit=true
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="NEXTCLOUD_CONFIG_DIR=${ncConfig}"
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncProvisionJob}/bin/nc-provision
        TimeoutStartSec=10min
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${backupRoot}
        RestrictAddressFamilies=AF_UNIX
      '';

      dataSyncService = pkgs.writeText "nextcloud-data-sync.service" ''
        [Unit]
        Description=Nextcloud user-data mirror — rsync data/ to dataSyncTarget (Nix-managed)

        [Service]
        Type=oneshot
        User=${ncUser}
        Group=${ncUser}
        UMask=0077
        Environment="PATH=/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncDataSyncJob}/bin/nc-data-sync
        TimeoutStartSec=4h
        NoNewPrivileges=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${dataSyncTarget}
        RestrictAddressFamilies=AF_UNIX
      '';

      dataSyncTimer = pkgs.writeText "nextcloud-data-sync.timer" ''
        [Unit]
        Description=Hourly user-data mirror sync (Nix-managed)

        [Timer]
        OnCalendar=hourly
        RandomizedDelaySec=5m
        Persistent=true

        [Install]
        WantedBy=timers.target
      '';
    in
    {
      packages.${system} = {
        inherit occ deploy;
        "apply-config" = applyConfigTool;
        "nc-backup" = ncBackupJob;
        "nc-restore" = ncRestoreJob;
        "nc-data-sync" = ncDataSyncJob;
        "nc-provision" = ncProvisionJob;
        "drives-mount" = drivesMount;
        "drives-umount" = drivesUmount;
        "drives-check" = drivesCheck;
        "zfs-install" = zfsInstall;
        "zfs-rehearse" = zfsRehearse;
        "zfs-disaster-mirror-create" = zfsDisasterCreate;
        "zfs-disaster-mirror-check" = zfsDisasterCheck;
        "zfs-disaster-mirror-remove" = zfsDisasterRemove;
        "zfs-create-primary" = zfsCreatePrimary;
        "zfs-create-backup" = zfsCreateBackup;
        "zfs-replicate" = zfsReplicate;
        "zfs-verify-migration" = zfsVerifyMigration;
        "nc-import-archive" = ncImportArchive;
        "nc-archive-share" = ncArchiveShare;
        "zfs-check" = zfsCheck;
        "provisioned-passwords" = zfsProvisionedPasswords;
        nextcloud = nc;
        php = phpEnv;
        postgresql = pg;
        caddyfile = caddyfile;
        default = deploy;
      };

      apps.${system} = {
        deploy = {
          type = "app";
          program = "${deploy}/bin/nextcloud-deploy";
        };
        occ = {
          type = "app";
          program = "${occ}/bin/nextcloud-occ";
        };
        default = self.apps.${system}.deploy;
      };

      checks.${system} = {
        caddyfile = pkgs.runCommand "caddyfile-validates" { } ''
          export HOME="$PWD" XDG_DATA_HOME="$PWD/data" XDG_CONFIG_HOME="$PWD/conf"
          mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
          ${caddy}/bin/caddy validate --config ${caddyfile} --adapter caddyfile
          touch $out
        '';
        phpenv = pkgs.runCommand "phpenv-built" { } ''
          ${phpEnv}/bin/php -v > $out
          grep -q pdo_pgsql <(${phpEnv}/bin/php -m)
        '';
        # unit-file verification moved to the container harness (tests/)
        # — sandboxed systemd-analyze insists on /run/systemd, and running it
        # inside the container against Ubuntu's systemd is more faithful.
        # shellcheck every generated bash script
        scriptsLint =
          pkgs.runCommand
            "scripts-shellcheck"
            {
              nativeBuildInputs = [ pkgs.shellcheck ];
            }
            ''
              shellcheck -S error \
                "${deploy}/bin/nextcloud-deploy" \
                "${occ}/bin/nextcloud-occ" \
                "${ncBackupJob}/bin/nc-backup" \
                "${ncRestoreJob}/bin/nc-restore" \
                "${ncDataSyncJob}/bin/nc-data-sync" \
                ${dbInit} \
                ${dbReady} \
                ${initScript} \
                "${zfsInstall}/bin/zfs-install" \
                "${zfsRehearse}/bin/zfs-rehearse" \
                "${zfsDisasterCreate}/bin/zfs-disaster-mirror-create" \
                "${zfsDisasterCheck}/bin/zfs-disaster-mirror-check" \
                "${zfsDisasterRemove}/bin/zfs-disaster-mirror-remove" \
                "${zfsCreatePrimary}/bin/zfs-create-primary" \
                "${zfsCreateBackup}/bin/zfs-create-backup" \
                "${zfsReplicate}/bin/zfs-replicate" \
                "${zfsVerifyMigration}/bin/zfs-verify-migration" \
                "${ncImportArchive}/bin/nc-import-archive" \
                "${ncArchiveShare}/bin/nc-archive-share" \
                "${zfsCheck}/bin/zfs-check" \
                "${ncProvisionJob}/bin/nc-provision" \
                "${zfsProvisionedPasswords}/bin/provisioned-passwords" \
                "${drivesMount}/bin/drives-mount" \
                "${drivesUmount}/bin/drives-umount" \
                "${drivesCheck}/bin/drives-check"
              touch $out
            '';
        # the generated PHP config-writer must parse
        applyConfigLint = pkgs.runCommand "applyconfig-php-lint" {
          nativeBuildInputs = [ phpEnv ];
        } ''
          ${phpEnv}/bin/php -l ${applyConfig} | tee lint.txt
          grep -q "No syntax errors" lint.txt
          touch $out
        '';
      };
    };
}
