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
      # The restic repository + passphrase live on the ZFS **primary** pool
      # (dataset `primary/restic`), not the root SSD: the repo grew without
      # bound on / and crowded the system disk. Living on primary also puts it
      # inside the replication set, so zfs-replicate keeps a send/receive
      # replica of the repo on the backup pool (backup/restic) — the repo then
      # has the same redundancy as the user data. The passphrase rides with the
      # repo so losing the root disk can never strand it; `zfs-restic-migrate`
      # moves a pre-existing root-disk repo in. backupRoot itself stays on root
      # for the interlock stamps, the disaster mirror and pre-zfs safety tars
      # (all must survive pool loss).
      resticDataset = "${zfsPoolPrimary}/restic"; # live repo (replicated)
      resticMount = "/var/backups/restic"; # its mountpoint
      resticReplica = "${zfsPoolBackup}/restic"; # send/receive replica
      resticReplicaMount = "${replicaMount}/restic"; # replica mountpoint
      resticRepo = "${resticMount}/repo";
      # root-disk fallback (containers/VM drills, un-migrated hosts)
      resticRepoFallback = "${backupRoot}/repo";
      # Resolve the restic base dir at runtime: prefer the mounted ZFS dataset,
      # else fall back to the root-disk location. Sets RESTIC_REPOSITORY and
      # RESTIC_PASSWORD_FILE (used by nc-backup + nc-restore). The pg_dump
      # staging dir deliberately stays on the root disk so the absolute paths
      # stored inside existing archives never change.
      resticBaseSh = ''
        RESTIC_BASE="${backupRoot}"
        if findmnt -no SOURCE "${resticMount}" 2>/dev/null | grep -qx "${resticDataset}"; then
          RESTIC_BASE="${resticMount}"
        fi
        export RESTIC_REPOSITORY="$RESTIC_BASE/repo"
        export RESTIC_PASSWORD_FILE="$RESTIC_BASE/.restic-pass"
      '';
      stashRoot = "${backupRoot}/staging"; # per-run pg_dump staging
      # same dump path as stored inside archives (no leading slash) — used by
      # restic restore --include during validation
      stashRelDump = lib.removePrefix "/" "${stashRoot}/nextcloud.dump";
      keepHourly = "24";
      keepDaily = "14";
      keepWeekly = "6";
      keepMonthly = "6";

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
        # the dry run prints the real commands from this very file (the block
        # between the APPLY markers) instead of restating them, so the plan
        # can never drift from what would actually run
        print_apply() {
          awk '/^[[:space:]]*# >>> APPLY[[:space:]]*$/{f=1; next} /^[[:space:]]*# <<< APPLY[[:space:]]*$/{f=0} f' "$0" | sed -e 's/^[[:space:]]*//'
        }
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: migration-complete stamp missing (run zfs-verify-migration first)" >&2; exit 1; }
        test -f ${migrationState}/import-complete \
          || { echo "refusing: import-complete stamp missing (finish nc-import-archive first)" >&2; exit 1; }
        if [ "''${CONFIRM:-}" != "disaster" ]; then
          echo "DRY RUN — nothing was changed. Set CONFIRM=disaster to proceed." >&2
          echo "would run:"
          print_apply
          exit 0
        fi
        # >>> APPLY
        rm -rf "${disasterMirror}"
        echo "disaster mirror removed — $(df -h / | tail -1 | awk '{print $4}') free on /"
        # <<< APPLY
      '';

      # purge the retired rsync mirror tree (${backupRoot}/data) — a root-disk
      # duplicate of data/ that the old nextcloud-data-sync timer kept
      # re-creating. Same shape as the other retire flows: the units must
      # already be gone (a live timer would just re-create the tree), the
      # replacement copy must be verified, and CONFIRM is typed.
      ncDataSyncPurge = pkgs.writeShellScriptBin "nc-data-sync-purge" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        # dry run prints the real commands from this file (APPLY markers)
        print_apply() {
          awk '/^[[:space:]]*# >>> APPLY[[:space:]]*$/{f=1; next} /^[[:space:]]*# <<< APPLY[[:space:]]*$/{f=0} f' "$0" | sed -e 's/^[[:space:]]*//'
        }
        MIRROR="${backupRoot}/data"
        [ -d "$MIRROR" ] || { echo "nothing to do: $MIRROR does not exist"; exit 0; }
        # a live timer would re-create the tree, and a running pass must not be
        # yanked mid-copy — deploy retires both (disable --now + stop + rm)
        if systemctl is-enabled nextcloud-data-sync.timer >/dev/null 2>&1 \
             || systemctl is-active nextcloud-data-sync.service >/dev/null 2>&1; then
          echo "refusing: nextcloud-data-sync is still enabled/active — run 'nix run .#deploy' first" >&2
          exit 1
        fi
        # the ZFS replica must be the verified surviving copy first
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: migration-complete stamp missing (run zfs-verify-migration first)" >&2; exit 1; }
        if [ "''${CONFIRM:-}" != "mirror" ]; then
          echo "DRY RUN — nothing was changed. Set CONFIRM=mirror to proceed." >&2
          echo "would delete the retired rsync mirror tree: $MIRROR (including its .trash)"
          echo "surviving copy: the ZFS replica ${replicaDataset}"
          echo "would run:"
          print_apply
          exit 0
        fi
        # >>> APPLY
        SZ="$(du -sh "$MIRROR" 2>/dev/null | cut -f1 || true)"
        rm -rf "$MIRROR"
        echo "mirror removed (freed ~''${SZ:-?}) — $(df -h / | tail -1 | awk '{print $4}') free on /"
        # <<< APPLY
      '';

      ncArchiveRetire = pkgs.writeShellScriptBin "nc-archive-retire" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        # dry run prints the real commands from this file (APPLY markers)
        print_apply() {
          awk '/^[[:space:]]*# >>> APPLY[[:space:]]*$/{f=1; next} /^[[:space:]]*# <<< APPLY[[:space:]]*$/{f=0} f' "$0" | sed -e 's/^[[:space:]]*//'
        }
        # gates: option B must be imported and verified, then a typed confirm
        test -f ${migrationState}/migration-complete \
          || { echo "refusing: migration-complete missing (run zfs-verify-migration first)" >&2; exit 1; }
        test -f ${migrationState}/import-complete \
          || { echo "refusing: import-complete missing (finish nc-import-archive first — this destroys the frozen pre-NC copy)" >&2; exit 1; }
        if [ "''${CONFIRM:-}" != "retire-archive" ]; then
          echo "DRY RUN — nothing was changed. Set CONFIRM=retire-archive to proceed." >&2
          echo "# would run, in order:"
          echo "#   1. disable nextcloud-archive-bind.service (and unmount the interim bind)"
          echo "#   2. delete the interim member shares on '/${archiveBindMountName}'"
          echo "#   3. destroy ${archiveDataset} + ${zfsPoolBackup}/archive, including all their snapshots"
          echo "# surviving copy: the verified option-B tree under ${ncDataDir}/${archiveOwner}/files (import-complete is stamped)"
          print_apply
          exit 0
        fi
        # >>> APPLY
        # retire the interim bind first (its dataset is about to disappear)
        systemctl disable --now nextcloud-archive-bind.service 2>/dev/null || true
        # retire the interim member shares, scoped to the interim folder only
        NAME="${archiveBindMountName}"
        PW="$(grep -ah "^uid=${archiveOwner} password=" ${ncRoot}/provision-credentials-*.log 2>/dev/null \
          | sed -E 's/^uid=[^ ]+ password=([^ ]+).*/\1/' | tail -1 || true)"
        if [ -n "$PW" ]; then
          IDS="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' -G \
            --data-urlencode "path=/$NAME" \
            "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json" \
            | grep -aoE '"id":"[0-9]+"' | grep -oE '[0-9]+' || true)"
          for i in $IDS; do
            curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' -X DELETE \
              "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares/$i" >/dev/null 2>&1 || true
          done
        fi
        # the unit's ExecStop unmounted the bind; drop the now-empty mountpoint
        # so the retired folder cannot linger in the archive user's files
        if ! findmnt -no SOURCE "${archiveBindWhere}" >/dev/null 2>&1; then
          rmdir "${archiveBindWhere}" 2>/dev/null || true
        fi
        # the mountpoint is gone, but its filecache rows are not: a datadir-wide
        # indexer (files:scan, memories' 15-minute IndexJob) then keeps tripping
        # over the phantom files ("File is not readable:
        # .../Archive (Read only)/...") because they no longer exist on disk. A
        # full-user scan drops the cached children missing on disk
        # (Scanner::handleChildren), which also lets memories' cleanupStale
        # drop the matching timeline rows.
        /usr/bin/sudo -u ${ncUser} env HOME=${ncRoot} NEXTCLOUD_CONFIG_DIR=${ncConfig} \
          ${phpEnv}/bin/php ${nc}/occ files:scan ${archiveOwner} \
          || echo "retire: filecache prune failed — run 'occ files:scan ${archiveOwner}' by hand" >&2
        echo "retire: destroying ${archiveDataset} and the replica pair"
        # mounted datasets refuse destroy — unmount first (the /mnt/archive
        # machine mount disappears with the dataset's own mountpoint)
        zfs umount ${archiveDataset} 2>/dev/null || true
        umount ${archiveSource} 2>/dev/null || true
        zfs umount ${zfsPoolBackup}/archive 2>/dev/null || true
        zfs destroy -r ${archiveDataset} 2>/dev/null || true
        zfs destroy -r ${zfsPoolBackup}/archive 2>/dev/null || true
        touch ${migrationState}/archive-retired
        echo "retire: done — replication skips the archive datasets from now on; space reclaimed as the pools free lazily"
        # <<< APPLY
      '';

      ncTranscodeUnplayable = pkgs.writeShellScriptBin "nc-transcode-unplayable" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        # gates: the option-B copy must exist and be complete
        test -f ${migrationState}/import-complete \
          || { echo "refusing: import-complete missing (nc-import-archive first)" >&2; exit 1; }
        STATE="$(cat ${migrationState}/import-share-name 2>/dev/null || true)"
        [ -n "$STATE" ] || { echo "import-share-name stamp missing" >&2; exit 1; }
        TDIR="${ncDataDir}/${archiveOwner}/files/$STATE"
        [ -d "$TDIR" ] || { echo "import tree $TDIR missing" >&2; exit 1; }
        FFMPEG=${ncToolsEnv}/bin/ffmpeg
        FFPROBE=${ncToolsEnv}/bin/ffprobe
        [ -x "$FFMPEG" ] || { echo "ffmpeg missing in ncToolsEnv (deploy first)" >&2; exit 1; }
        echo "transcode: scanning $TDIR for undecodable video/audio codecs"
        N=0
        # a plain `find | while` pipeline would run the loop in a subshell:
        # the N counter increments would never reach the summary echo. Feed
        # the loop via process substitution instead. NOTE: in a nix indented
        # string a backslash is literal — a single trailing backslash here is
        # what bash needs for the EOL continuation (see tests + AGENTS.md)
        while IFS= read -r -d ''' f; do
          V="$("$FFPROBE" -v quiet -show_entries stream=codec_name,codec_type -of csv=p=0 "$f" 2>/dev/null | tr '\n' ' ' || true)"
          case "$V" in
            *mjpeg*|*h263*|*mpeg4*|*dvvideo*|*msvideo*|*wmv1*|*wmv2*|*wmav2*|*pcm_*|*gsm*|*adpcm*)
              : # needs conversion
              ;;
            *) continue ;;
          esac
          OUT="''${f%.*}.mp4"          # same basename => converts in place for mp4 sources
          TMP="$OUT.part"
          echo "transcode: $f"
          "$FFMPEG" -hide_banner -loglevel warning -y -i "$f" -f mp4 \
            -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
            -c:a aac -b:a 128k -movflags +faststart "$TMP"
          mv -f "$TMP" "$OUT"
          N=$((N + 1))
        done < <(find "$TDIR" -type f \( -iname '*.mov' -o -iname '*.avi' -o -iname '*.wmv' \
          -o -iname '*.mkv' -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.mp4' \) -print0)
        echo "transcode: done ($N files converted to h264/aac)"
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

        # share name: the archive's own span — oldest..newest file year in the
        # source — stamped once and never renamed. Deriving the END year from
        # the newest file rather than "now" keeps the name stable across years
        # (and matches what a hand-curated span looks like).
        STATE="${migrationState}/import-share-name"
        if [ -s "$STATE" ]; then
          NAME="$(cat "$STATE")"
        else
          YEARS="$(find "${archiveSource}" -type f -printf '%T+\n' 2>/dev/null \
            | cut -d- -f1 | grep -E '^(19|20)[0-9][0-9]$' | sort -u || true)"
          OLD="$(printf '%s\n' "$YEARS" | head -1 || true)"
          NEW="$(printf '%s\n' "$YEARS" | tail -1 || true)"
          [ -n "$OLD" ] || OLD="$(date +%Y)"
          [ -n "$NEW" ] || NEW="$(date +%Y)"
          NAME="Archive $OLD-$NEW"
          # never copy twice: if a tree already exists under another
          # Archive <y>-<y> name, adopt it instead of computing a new one
          # (the exact pattern keeps the interim bind "Archive (Read only)"
          # out of the match)
          FILES="${ncDataDir}/${archiveOwner}/files"
          EXISTING="$(find "$FILES" -maxdepth 1 -mindepth 1 -type d \
            -name 'Archive [0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]' \
            -printf '%f\n' 2>/dev/null || true)"
          if [ -n "$EXISTING" ] && ! printf '%s\n' "$EXISTING" | grep -qxF "$NAME"; then
            NEX="$(printf '%s\n' "$EXISTING" | grep -c . || true)"
            [ "$NEX" = 1 ] || { echo "refusing: ''${NEX} archive folders exist and none is '$NAME':" >&2
                               printf '  %s\n' "$EXISTING" >&2
                               echo "write ''${STATE} by hand to pick one, then rerun" >&2; exit 1; }
            echo "archive: adopting existing folder '$EXISTING' (not '$NAME')"
            NAME="$EXISTING"
          fi
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
          "${pkgs.rsync}/bin/rsync" -aH --chown=${ncUser}:${ncUser} --info=progress2 \
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
            *'"share_with":"'"$m"'"'*) continue ;;
          esac
          RESP="$(curl -sS -u "${archiveOwner}:$PW" -H 'OCS-APIRequest: true' \
            --data-urlencode "path=/$NAME" \
            --data-urlencode "shareType=0" \
            --data-urlencode "shareWith=$m" \
            --data-urlencode "permissions=${archiveSharePerms}" \
            "${ncWebUrl}/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json")"
          echo "$RESP" | grep -aq '"statuscode":200' \
            || { echo "share with member $m failed: $RESP" >&2; exit 1; }
          echo "archive: shared '$NAME' with member $m"
          CREATED=$((CREATED + 1))
        done
        [ "$CREATED" = 0 ] && echo "archive: member shares already present for all of ${archiveShareGroup}"
        # share-aware filecache refresh: after the shares exist, a second scan
        # updates the shared nodes' cached permissions — without it the
        # recipients' DAV resolves the subtree 404 on write ops (delete etc.)
        OCC files:scan --path="${archiveOwner}/files/$NAME" 2>&1 | tail -4

        touch ${migrationState}/import-complete
        echo "archive: import complete — '$NAME' shared with ${archiveShareGroup} members"
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
        # share-aware filecache refresh: after the shares exist, a second scan
        # updates the shared nodes' cached permissions — without it the
        # recipients' DAV resolves the subtree 404 on write ops (delete etc.)
        OCC files:scan --path="${archiveOwner}/files/$NAME" 2>&1 | tail -4
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
      # GFS snapshot policy (Sanoid) for the Nextcloud datadir. One snapshot
      # per period, so the counts are also the time windows: 24h of hourlies,
      # 7d dailies, 4w weeklies, 3 months of monthlies. Sanoid takes the tier
      # snapshots itself and prunes each tier to its count (it does not
      # promote one tier into the next); Syncoid mirrors the resulting set to
      # the backup pool. The restic repo is not GFS-snapshotted: restic
      # already keeps its own hourly/daily history, so Syncoid uses a rolling
      # sync snapshot for that dataset instead.
      zfsKeepHourly = "24";
      zfsKeepDaily = "7";
      zfsKeepWeekly = "4";
      zfsKeepMonthly = "3";
      sanoidConfig = pkgs.writeTextDir "sanoid.conf" ''
        [template_gfs]
            frequently = 0
            hourly = ${zfsKeepHourly}
            daily = ${zfsKeepDaily}
            weekly = ${zfsKeepWeekly}
            monthly = ${zfsKeepMonthly}
            yearly = 0
            autosnap = yes
            autoprune = yes

        [${zfsPoolPrimary}/nextcloud]
            use_template = gfs
      '';
      # archive import (plan of record): copy the archive dataset into a
      # service user's folder and group-share it; completes with import-complete
      archiveOwner = "archive";
      archiveShareGroup = "parents";
      archiveSharePerms = "15"; # read+change+create+delete, no re-share
      archiveSource = "/mnt/archive";
      ncWebUrl = "http://127.0.0.1:${webPort}";
      # NC store apps the deploy installs + enables; add an app here and a
      # deploy brings it in (the store resolves the platform-compatible
      # version; NC 34 -> music 3.3.1, files_archive 1.3.2, memories current)
      storeApps = [ "music" "files_archive" "memories" ];
      storeAppsJoined = lib.concatStringsSep " " storeApps;
      # the archive manager app is vendored: the author's release tarball,
      # hash-pinned here (declared NC 33-35, so NC 34 is in range) and
      # extracted into store-apps at deploy — app upgrades are flake edits
      filesArchiveApp = pkgs.fetchurl {
        url = "https://github.com/rotdrop/nextcloud-app-files-archive/releases/download/v1.3.2/files_archive-1.3.2.tar.gz";
        hash = "sha256-3pXkwvQ1O8+CajdXLzIcV/X7E7U85yCrKbKXgwAmJXw=";
      };
      # E-Book Reader is not yet published to the NC app store, so vendor the
      # author's hash-pinned release tarball (declared NC 33-35, PHP 8.2+;
      # zip/gd/dom/mbstring are in phpEnv) and enable it from store-apps.
      ebookReaderApp = pkgs.fetchurl {
        url = "https://github.com/SomeCatCode/nextcloud_ebook_reader/releases/download/v1.0.1/ebookreader.tar.gz";
        hash = "sha256-xdiQSLfxn6BzoBhO2MCjsYVBEcRkpQlpUG7SLKtgEFU=";
      };
      # interim: the archive dataset binds INTO the datadir (zero copy) and is
      # served as a native shared folder; option B's copy replaces this later
      archiveBindMountName = "Archive (Read only)";
      archiveBindWhere = "${ncDataDir}/${archiveOwner}/files/${archiveBindMountName}";
      archiveBindService = pkgs.writeText "nextcloud-archive-bind.service" ''
        [Unit]
        Description=Nextcloud archive dataset bind-mounted into the datadir (interim, read-only in practice)
        ConditionPathIsDirectory=${archiveSource}
        # after nc-archive-retire the dataset (and the reason for this bind) is
        # gone — never let a deploy or boot resurrect an empty
        # "Archive (Read only)" folder in the archive user's files
        ConditionPathExists=!${migrationState}/archive-retired
        # the bind lands INSIDE the archive user's home — the account must
        # exist first (its creation refuses when the home already holds files)
        # Requires pulls init AND provision into the transaction (After only
        # orders — without the pull, provision spawned before init created
        # ncRoot and died at namespace setup)
        Requires=nextcloud-init.service nextcloud-provision.service
        After=nextcloud-init.service nextcloud-provision.service
        [Service]
        Type=oneshot
        RemainAfterExit=true
        ExecStartPre=/usr/bin/install -d -o ${ncUser} -g ${ncUser} -m 0770 "${archiveBindWhere}"
        # idempotent bind: a bare mount --bind on an already-bound path stacks
        # another layer, and every deploy restarts this unit — the real host
        # reached 32 layers here (the stack survived because umount fails
        # "target is busy" while anything holds the bind, and only one layer
        # came off per attempt)
        ExecStart=/usr/bin/sh -c 'findmnt -no SOURCE "${archiveBindWhere}" 2>/dev/null | grep -qx "${archiveDataset}" || exec /usr/bin/mount --bind "${archiveSource}" "${archiveBindWhere}"'
        # peel EVERY layer we ever stacked (umount removes the top one).
        # The layers are peers of one shared propagation group, so a plain
        # umount tries to detach every peer at once and fails EBUSY when any
        # one of them is held — break the group first. Succeed once the path
        # is no longer our bind.
        ExecStop=/usr/bin/sh -c 'while findmnt -no SOURCE "${archiveBindWhere}" >/dev/null 2>&1; do /usr/bin/mount --make-private "${archiveBindWhere}" 2>/dev/null; umount "${archiveBindWhere}" 2>/dev/null || break; done; ! findmnt -no SOURCE "${archiveBindWhere}" 2>/dev/null | grep -qx "${archiveDataset}"'
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
      # Redis (nix-built): the distributed + locking memcache Memories wants.
      # Cache-only (no persistence), loopback TCP, dedicated dynamic user.
      redisMaxmemory = "2gb";
      redisConf = pkgs.writeText "redis-nc.conf" ''
        port 0
        unixsocket /run/redis-nc/redis.sock
        unixsocketperm 0770
        protected-mode yes
        save ""
        appendonly no
        maxmemory ${redisMaxmemory}
        maxmemory-policy allkeys-lru
      '';
      redisUnit = pkgs.writeText "nextcloud-redis.service" ''
        [Unit]
        Description=Redis for Nextcloud memcache (nix-managed, cache-only)
        After=network.target

        [Service]
        Type=simple
        DynamicUser=yes
        Group=${ncUser}
        RuntimeDirectory=redis-nc
        RuntimeDirectoryMode=0770
        StateDirectory=redis-nc
        StateDirectoryMode=0700
        ExecStart=${pkgs.redis}/bin/redis-server ${redisConf}
        Restart=on-failure
        RestartSec=3
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true

        [Install]
        WantedBy=multi-user.target
      '';
      ncUser = "nextcloud";
      webUser = "nc-caddy"; # caddy runs as this, gets socket access via group
      # the runtime tools the NC services need on their PATH (nix-built env;
      # the unit PATH lines bake this store path at eval time - no symlinks
      # into system directories)
      ncToolsEnv = pkgs.buildEnv {
        name = "nextcloud-host-tools";
        paths = [ pkgs.ffmpeg pkgs.p7zip ];
        pathsToLink = [ "/bin" ];
      };
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
                  redis
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

          # store-apps apps' static assets (the apps_paths url: /store-apps)
          # block the dirs that hold executable PHP / build sources
          @sa-protected path /store-apps/*/lib/* /store-apps/*/vendor-scoped/* /store-apps/*/composer/* /store-apps/*/appinfo/signature.json
          respond @sa-protected 404

          handle /store-apps/* {
            root /var/lib/nextcloud
            file_server
          }

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
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_INET AF_INET6
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
        $CONFIG['memcache.distributed'] = '\\OC\\Memcache\\Redis';
        $CONFIG['memcache.locking'] = '\\OC\\Memcache\\Redis';
        $CONFIG['redis'] = [
          'host' => '/run/redis-nc/redis.sock',
          'port' => 0,
        ];
        // memories: live video transcode on + the go-vod callback to the
        // instance's actual HTTP port (default localhost:80 doesn't serve).
        // The bundled go-vod binary spawns per playback from bin-ext.
        $CONFIG['memories.vod.disable'] = false;
        $CONFIG['memories.vod.nc_url'] = 'http://127.0.0.1:55555';
        // video/grid previews: add the Movie provider (video/* via ffmpeg) and
        // pin the binaries from the tools env explicitly - the Movie provider
        // reads preview_ffprobe_path and derives its ffmpeg from that dir
        $CONFIG['preview_ffmpeg_path'] = '${ncToolsEnv}/bin/ffmpeg';
        $CONFIG['preview_ffprobe_path'] = '${ncToolsEnv}/bin/ffprobe';
        $CONFIG['enabledPreviewProviders'] = [
          'OC\\Preview\\PNG',
          'OC\\Preview\\JPEG',
          'OC\\Preview\\GIF',
          'OC\\Preview\\BMP',
          'OC\\Preview\\XBitmap',
          'OC\\Preview\\MP3',
          'OC\\Preview\\TXT',
          'OC\\Preview\\MarkDown',
          'OC\\Preview\\Krita',
          'OC\\Preview\\HEIC',
          'OC\\Preview\\Photoshop',
          'OC\\Preview\\Postscript',
          'OC\\Preview\\SVG',
          'OC\\Preview\\TIFF',
          'OC\\Preview\\WEBP',
          'OC\\Preview\\Movie',
        ];
        // keep preview sizes sane for a 577G library (the docs' tuning)
        $CONFIG['preview_max_x'] = 2048;
        $CONFIG['preview_max_y'] = 2048;
        $CONFIG['jpeg_quality'] = 60;
        // user-facing restore window: keep every deleted file for at least 30
        // days, then delete it (30, 30 -> no space-pressure early expiry)
        $CONFIG['trashbin_retention_obligation']  = '30, 30';
        // bound version growth: keep edits for at least 30 days, delete after 90
        $CONFIG['versions_retention_obligation']  = '30, 90';
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
        export PATH="/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        export NIX_CONFIG="experimental-features = nix-command flakes"

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
        install -m 0644 ${zfsSyncService} ${unitDir}/nextcloud-sync.service
        install -m 0644 ${zfsSyncTimer} ${unitDir}/nextcloud-sync.timer
        install -m 0644 ${redisUnit} ${unitDir}/nextcloud-redis.service
        install -m 0644 ${provisionService} ${unitDir}/nextcloud-provision.service
        install -m 0644 ${archiveBindService} ${unitDir}/nextcloud-archive-bind.service
        # retire the pre-rename .mount unit (idempotent; safe on fresh hosts)
        systemctl disable --now var-lib-nextcloud-data-archive-files-Archive.mount 2>/dev/null || true
        # ... and drop the file, so no target can ever start it again
        rm -f ${unitDir}/var-lib-nextcloud-data-archive-files-Archive.mount
        # peel EVERY layer the old unit stacked — a single umount left the rest
        # mounted, which is how the stack survived deploys (32 deep, Nov 2026).
        # The layers are peers in one shared propagation group: a plain umount
        # tries to detach all peers and fails EBUSY if any is held, so break
        # the group before each umount.
        ARCHIVE_BIND="${ncDataDir}/${archiveOwner}/files/Archive"
        while findmnt -no SOURCE "$ARCHIVE_BIND" >/dev/null 2>&1; do
          mount --make-private "$ARCHIVE_BIND" 2>/dev/null || true
          umount "$ARCHIVE_BIND" 2>/dev/null || break
        done
        if ! findmnt -no SOURCE "${ncDataDir}/${archiveOwner}/files/Archive" >/dev/null 2>&1; then
          rm -rf "${ncDataDir}/${archiveOwner}/files/Archive" 2>/dev/null || true
        fi
        # retire the rsync data mirror (idempotent; safe on fresh hosts) — the
        # units are no longer shipped, but an existing host still has them
        # enabled and would keep copying data/ onto the root disk
        systemctl disable --now nextcloud-data-sync.timer 2>/dev/null || true
        # disabling the timer does NOT kill a run the timer already started,
        # and one full mirror pass can run for hours (re-filling the root disk
        # the whole time) — stop the in-flight service instance too
        systemctl stop nextcloud-data-sync.service 2>/dev/null || true
        systemctl reset-failed nextcloud-data-sync.service 2>/dev/null || true
        rm -f ${unitDir}/nextcloud-data-sync.service ${unitDir}/nextcloud-data-sync.timer

        echo "== backup roots =="
        install -d -o ${ncUser} -g ${ncUser} -m 0700 ${backupRoot} ${stashRoot}
        # restic repo lives on the ZFS primary pool (replicated to backup):
        # create its dataset once the pool exists (idempotent; no-op on
        # un-migrated hosts and in the container/VM drills, which have no zfs).
        # Falls back to the root-disk location until then.
        if command -v zfs >/dev/null 2>&1 \
             && zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolPrimary} \
             && ! zfs list -H -o name ${resticDataset} >/dev/null 2>&1; then
          echo "deploy: creating restic dataset ${resticDataset} (mountpoint ${resticMount})"
          zfs create -o mountpoint=${resticMount} ${resticDataset}
        fi
        if findmnt -no SOURCE ${resticMount} 2>/dev/null | grep -qx ${resticDataset}; then
          install -d -o ${ncUser} -g ${ncUser} -m 0700 ${resticMount} ${resticRepo}
        else
          install -d -o ${ncUser} -g ${ncUser} -m 0700 ${resticRepoFallback}
        fi

        systemctl daemon-reload
        echo "== restarting to pick up the current build =="
        systemctl daemon-reload
        # restarts run BEFORE the enable list: the bind's Requires chain
        # (init+provision) fires at enable time and must find the fresh units
        # (e.g. socket-configured redis) already running
        systemctl restart nextcloud-redis.service
        systemctl restart nextcloud-db.service
        systemctl restart nextcloud-fpm.service
        systemctl restart nextcloud-caddy.service
        systemctl restart nextcloud-init.service
        systemctl restart nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer
        systemctl restart nextcloud-provision.service

        echo "== enabling services =="
        systemctl enable --now \
          nextcloud-redis.service \
          nextcloud-db.service \
          nextcloud-fpm.service \
          nextcloud-caddy.service \
          nextcloud-init.service \
          nextcloud-backup.timer \
          nextcloud-snapshot.timer \
          nextcloud-sync.timer \
          nextcloud-cron.timer
        # the interim archive bind exists only before nc-archive-retire; after
        # retirement the imported copy is native NC content, so a deploy must
        # not bind the (now empty) archive source back into the archive user's
        # files or recreate the "Archive (Read only)" mountpoint
        if [ -f ${migrationState}/archive-retired ]; then
          systemctl disable --now nextcloud-archive-bind.service 2>/dev/null || true
          rmdir "${archiveBindWhere}" 2>/dev/null || true
        else
          systemctl enable --now nextcloud-archive-bind.service
        fi

        echo "== ffmpeg + p7zip (nix env) + music app =="
        # the music app installs from the NC app store: platform versioning
        # and code signatures are the store's job; the version follows the
        # store's latest-compatible release at install time (upgrades happen
        # via app:upgrade). Vendoring was dropped: the music project's 3.x
        # tarballs are store-only (public GitHub releases cap at NC 32)
        install -d -o ${ncUser} -g ${ncUser} -m 0755 ${ncStoreApps}
        # store apps: the flake's storeApps list declares which apps are
        # wanted; the NC app store handles platform versioning + signatures
        # (app:install + app:enable are both idempotent; app versions follow
        # the store's latest-compatible releases, upgrades via app:upgrade)
        install -d -o ${ncUser} -g ${ncUser} -m 0755 ${ncStoreApps}
        for a in ${storeAppsJoined}; do
          nix run .#occ -- app:install "$a" 2>&1 | tail -1 || true
          nix run .#occ -- app:enable "$a" 2>&1 | tail -1 || true
        done
        # the archive manager (vendored, hash-pinned)
        FATA="$(nix build --no-link --print-out-paths .#files-archive-app 2>/dev/null | tail -1)"
        rm -rf ${ncStoreApps}/files_archive
        tar xzf "$FATA" -C ${ncStoreApps}
        chown -R ${ncUser}:${ncUser} ${ncStoreApps}/files_archive
        nix run .#occ -- app:enable files_archive 2>&1 | tail -1 || true
        # E-Book Reader (vendored: not yet in the NC app store)
        EBRA="$(nix build --no-link --print-out-paths .#ebookreader-app 2>/dev/null | tail -1)"
        rm -rf ${ncStoreApps}/ebookreader
        tar xzf "$EBRA" -C ${ncStoreApps}
        chown -R ${ncUser}:${ncUser} ${ncStoreApps}/ebookreader
        nix run .#occ -- app:enable ebookreader 2>&1 | tail -1 || true
        systemctl restart nextcloud-fpm.service

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
                 nextcloud-sync.timer; do
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
        ${resticBaseSh}

        # never silently start a fresh repo on the pool while a real one still
        # sits on the root disk (e.g. deploy created the dataset but the repo
        # was not migrated yet) — that would strand the whole backup history
        if [ "$RESTIC_BASE" != "${backupRoot}" ] \
             && [ ! -e "$RESTIC_REPOSITORY/config" ] \
             && [ -e "${backupRoot}/repo/config" ]; then
          echo "nc-backup: a restic repo exists at ${backupRoot}/repo but the pool repo is empty" >&2
          echo "nc-backup: run 'just zfs-restic-migrate' to move it onto the pool first" >&2
          exit 1
        fi

        OCC() { ${phpEnv}/bin/php ${nc}/occ "$@"; }

        mkdir -p "${backupRoot}" "$RESTIC_REPOSITORY" "${stashRoot}"
        chmod 0700 "${backupRoot}" "${stashRoot}" "$RESTIC_BASE"
        if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$RESTIC_PASSWORD_FILE"
          chmod 0600 "$RESTIC_PASSWORD_FILE"
          echo "nc-backup: generated restic password file $RESTIC_PASSWORD_FILE"
        fi
        if [ ! -e "$RESTIC_REPOSITORY/config" ]; then
          echo "nc-backup: initialising restic repository at $RESTIC_REPOSITORY"
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
        ${resticBaseSh}
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncBackupJob}/bin/nc-backup full
        TimeoutStartSec=4h
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        # restic repo may live on the ZFS backup pool (-: tolerate absent path
        # on un-migrated hosts / drills without zfs)
        ReadWritePaths=${ncRoot} ${backupRoot} -${resticMount}
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncBackupJob}/bin/nc-backup incremental
        TimeoutStartSec=2h
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${backupRoot} -${resticMount}
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
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
        # dry run prints the real commands from this file (APPLY markers)
        print_apply() {
          awk '/^[[:space:]]*# >>> APPLY[[:space:]]*$/{f=1; next} /^[[:space:]]*# <<< APPLY[[:space:]]*$/{f=0} f' "$0" | sed -e 's/^[[:space:]]*//'
        }
        # sudo env_reset strips PATH and the nix feature flags the tail needs
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
        export NIX_CONFIG="experimental-features = nix-command flakes"
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
        # dry run by default: everything above is read-only, so print the real
        # commands (APPLY block) and stop unless the operator typed the CONFIRM
        if [ "''${CONFIRM:-}" != "primary" ]; then
          echo "DRY RUN — nothing was changed. Set CONFIRM=primary to proceed." >&2
          echo "# would: destroy ${primaryDisk} (sdc1 NTFS), create the ${zfsPoolPrimary} pool,"
          echo "# move the live datadir ${ncDataDir} onto ${zfsPoolPrimary}/nextcloud and"
          echo "# import the sdc1 content into ${zfsPoolPrimary}/nextcloud + ${archiveDataset}"
          echo "# verified second copy: ${disasterMirror} ($(find ${disasterMirror} -type f 2>/dev/null | wc -l) files)"
          print_apply
          exit 0
        fi
        # >>> APPLY
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
            nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer \
            nextcloud-sync.service nextcloud-provision.service nextcloud-cron.timer 2>/dev/null || true
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
        # restic repo dataset (idempotent — covers the resume path too)
        zfs list -H -o name ${resticDataset} >/dev/null 2>&1 \
          || zfs create -o mountpoint=${resticMount} ${resticDataset}
        install -d -o ${ncUser} -g ${ncUser} -m 0700 ${resticMount}
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
        # <<< APPLY
      '';

      zfsCreateBackup = pkgs.writeShellScriptBin "zfs-create-backup" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo CONFIRM="''${CONFIRM:-}" "$0" "$@"
        # dry run prints the real commands from this file (APPLY markers)
        print_apply() {
          awk '/^[[:space:]]*# >>> APPLY[[:space:]]*$/{f=1; next} /^[[:space:]]*# <<< APPLY[[:space:]]*$/{f=0} f' "$0" | sed -e 's/^[[:space:]]*//'
        }
        test -f ${migrationState}/phase2-complete \
          || { echo "refusing: phase-2 stamp missing (run zfs-create-primary first)" >&2; exit 1; }
        # dry run by default (everything above is read-only)
        if [ "''${CONFIRM:-}" != "backup" ]; then
          echo "DRY RUN — nothing was changed. Set CONFIRM=backup to proceed." >&2
          echo "# would destroy ${backupDisk} (sdb1 NTFS mirror), create the ${zfsPoolBackup} pool,"
          echo "# then seed ${zfsPoolBackup}/nextcloud-data, ${zfsPoolBackup}/archive and ${resticReplica}"
          echo "# from the verified ${zfsPoolPrimary} datasets"
          print_apply
          exit 0
        fi
        # >>> APPLY
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
        # ensure the restic repo dataset exists on primary before the recursive
        # seed snapshot — it is part of the replication set now
        zfs list -H -o name ${resticDataset} >/dev/null 2>&1 \
          || zfs create -o mountpoint=${resticMount} ${resticDataset}
        install -d -o ${ncUser} -g ${ncUser} -m 0700 ${resticMount}
        TS="$(date +%Y%m%d%H%M%S)"
        zfs snapshot -r ${zfsPoolPrimary}@seed-$TS
        echo "backup: seeding replica via zfs send/receive"
        # -o mountpoint keeps each replica out of the primary's mountpoints
        # (sent properties would otherwise aim it at the live datadir/repo)
        zfs send -R ${zfsPoolPrimary}/nextcloud@seed-$TS \
          | zfs receive -F -o mountpoint=${replicaMount}/nextcloud-data ${replicaDataset}
        # the interim archive is gone once nc-archive-retire ran; a re-seed on
        # such a host must not try to send a dataset that no longer exists
        if zfs list -H -o name ${archiveDataset} >/dev/null 2>&1; then
          zfs send -R ${archiveDataset}@seed-$TS \
            | zfs receive -F -o mountpoint=${replicaMount}/archive ${zfsPoolBackup}/archive
        else
          echo "backup: ${archiveDataset} retired — seeding nextcloud + restic only"
        fi
        zfs send -R ${resticDataset}@seed-$TS \
          | zfs receive -F -o mountpoint=${resticReplicaMount} ${resticReplica}
        FB="$(find ${replicaMount}/nextcloud-data -type f 2>/dev/null | wc -l)"
        FA="$(find ${replicaMount}/archive -type f 2>/dev/null | wc -l)"
        echo "backup: replica files: nextcloud-data=$FB archive=$FA"
        echo "backup: restic repo replicated -> ${resticReplica} (mountpoint ${resticReplicaMount})"
        touch ${migrationState}/phase3-complete
        echo "backup: phase-3 complete — replica seeded on the backup drive"
        # <<< APPLY
      '';

      zfsReplicate = pkgs.writeShellScriptBin "zfs-replicate" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        # a manual run (or the previous timer tick) must not overlap this one:
        # syncoid has no lock of its own, and a long send can outlive the hour
        exec 9>/run/nextcloud-sync.lock
        flock -n 9 || { echo "replicate: another sync is already running — skipping"; exit 0; }

        zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolPrimary} \
          || { echo "replicate: primary pool missing" >&2; exit 1; }
        findmnt -no SOURCE ${ncDataDir} 2>/dev/null | grep -qx ${ncDataset} \
          || { echo "replicate: ${ncDataset} is not mounted at ${ncDataDir}" >&2; exit 1; }
        if zfs list -H -o name ${resticDataset} >/dev/null 2>&1; then
          findmnt -no SOURCE ${resticMount} 2>/dev/null | grep -qx ${resticDataset} \
            || { echo "replicate: ${resticDataset} is not mounted at ${resticMount}" >&2; exit 1; }
        fi

        # Sanoid owns snapshot creation + time-based GFS pruning. The cache and
        # run dirs are recreated idempotently (the host is not NixOS, so there
        # is no tmpfiles.d rule for them).
        install -d -m 0700 /var/cache/sanoid /run/sanoid
        ${pkgs.sanoid}/bin/sanoid \
          --configdir=${sanoidConfig} \
          --cache-dir=/var/cache/sanoid \
          --run-dir=/run/sanoid \
          --force-update \
          --cron

        if ! zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolBackup}; then
          echo "replicate: backup pool missing — snapshots taken, replication skipped" >&2
          exit 1
        fi

        # The nextcloud datadir uses only the snapshots Sanoid just made
        # (--no-sync-snap), keeps the replica's snapshot set identical to the
        # source (--delete-target-snapshots), and must not inherit the
        # source's mountpoint (the replica is mounted under ${replicaMount}).
        RC=0
        ${pkgs.sanoid}/bin/syncoid --no-sync-snap --delete-target-snapshots \
          --recvoptions="x mountpoint" \
          ${zfsPoolPrimary}/nextcloud ${replicaDataset} || RC=1

        if zfs list -H -o name ${resticDataset} >/dev/null 2>&1; then
          # restic already versions its repo inside the dataset; let Syncoid
          # create/recycle its own syncoid_* snapshot rather than adding a
          # second GFS history of the same backup catalog.
          ${pkgs.sanoid}/bin/syncoid --delete-target-snapshots \
            --recvoptions="x mountpoint" \
            ${resticDataset} ${resticReplica} || RC=1
        fi

        # The interim archive is retired on current hosts; keep replicating it
        # on hosts that are still in the import window (its snapshots predate
        # Sanoid, so --no-sync-snap just ships the existing ones).
        if zfs list -H -o name ${archiveDataset} >/dev/null 2>&1; then
          ${pkgs.sanoid}/bin/syncoid --no-sync-snap --delete-target-snapshots \
            --recvoptions="x mountpoint" \
            ${archiveDataset} ${zfsPoolBackup}/archive || RC=1
        else
          echo "replicate: archive datasets retired — not replicating them"
        fi

        [ "$RC" -eq 0 ] || { echo "replicate: one or more syncoid runs failed" >&2; exit 1; }
        date -u +"%Y-%m-%dT%H:%M:%SZ" > ${primaryMount}.last-replication
        echo "replicate: done (sanoid ${zfsKeepHourly}h/${zfsKeepDaily}d/${zfsKeepWeekly}w/${zfsKeepMonthly}m; replica ${replicaDataset} + ${resticReplica})"
      '';

      zfsSyncService = pkgs.writeText "nextcloud-sync.service" ''
        [Unit]
        Description=Nextcloud ZFS snapshots + replication (Nix-managed)
        After=zfs-mount.service
        Wants=zfs-mount.service
        # the timer is installed everywhere, but only a live ZFS datadir needs
        # this job; an un-migrated or unmounted host is skipped cleanly
        ConditionPathIsMountPoint=${ncDataDir}

        [Service]
        Type=oneshot
        ExecStart=${zfsReplicate}/bin/zfs-replicate
        # a full re-seed / long incremental send must not be killed by the
        # default startup timeout; the wrapper's flock keeps ticks serialized
        TimeoutStartSec=0
        Nice=10
        IOSchedulingClass=idle
      '';

      zfsSyncTimer = pkgs.writeText "nextcloud-sync.timer" ''
        [Unit]
        Description=Hourly Nextcloud ZFS snapshot + replication (Nix-managed)

        [Timer]
        OnCalendar=hourly
        RandomizedDelaySec=5m
        Persistent=true

        [Install]
        WantedBy=timers.target
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
        # skip the .zfs snapshot view: with snapdir=visible, find would
        # otherwise walk every snapshot instead of the live replica
        REP="$(find ${replicaMount} -path '*/.zfs' -prune -o -type f -print 2>/dev/null | wc -l)"
        [ "$REP" -ge 1 ] || { echo "replica empty" >&2; exit 1; }
        touch ${migrationState}/migration-complete
        echo "migration verified — the disaster mirror stays as the second copy until the archive
        # import completes; removal stays manual and gated (CONFIRM=disaster)"
      '';

      # Move a pre-existing (root-disk) restic repo + passphrase onto the ZFS
      # primary-pool dataset (which zfs-replicate then mirrors to the backup
      # pool). Idempotent, non-destructive: the source is kept (renamed) until
      # the copy verifies. Needs the dataset mounted (run the migration +
      # a deploy first).
      zfsResticMigrate = pkgs.writeShellScriptBin "zfs-restic-migrate" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        # create the dataset on demand (existing primary pool, pre-dates this
        # recipe) so `just zfs-restic-migrate` works standalone
        if command -v zfs >/dev/null 2>&1 \
             && zpool list -H -o name 2>/dev/null | grep -qx ${zfsPoolPrimary} \
             && ! zfs list -H -o name ${resticDataset} >/dev/null 2>&1; then
          echo "restic-migrate: creating dataset ${resticDataset} (mountpoint ${resticMount})"
          zfs create -o mountpoint=${resticMount} ${resticDataset}
          install -d -o ${ncUser} -g ${ncUser} -m 0700 ${resticMount}
        fi

        findmnt -no SOURCE ${resticMount} 2>/dev/null | grep -qx ${resticDataset} \
          || { echo "refusing: ${resticDataset} not mounted at ${resticMount} (finish the migration + deploy first)" >&2; exit 1; }

        TS="$(date +%Y%m%d-%H%M%S)"
        DEST_REPO=${resticMount}/repo
        SRC_REPO=${backupRoot}/repo
        DEST_PASS=${resticMount}/.restic-pass
        SRC_PASS=${backupRoot}/.restic-pass

        if [ ! -e "$SRC_REPO/config" ]; then
          echo "restic-migrate: no legacy repo at $SRC_REPO — nothing to migrate"
          echo "(a deploy initialises the pool repo on the next backup run)"
          exit 0
        fi
        if [ -e "$DEST_REPO/config" ]; then
          DEST_N="$(env RESTIC_REPOSITORY="$DEST_REPO" RESTIC_PASSWORD_FILE="$DEST_PASS" \
            ${restic}/bin/restic snapshots --compact 2>/dev/null \
            | grep -cE '^[0-9a-f]{8}' || true)"
          if [ "$DEST_N" != "0" ]; then
            echo "restic-migrate: repo already on the pool ($DEST_REPO, $DEST_N snapshots) — nothing to do"
            exit 0
          fi
          echo "restic-migrate: pool repo is empty — moving it aside before the copy"
          mv "$DEST_REPO" "''${DEST_REPO}.empty-$TS"
        fi

        echo "restic-migrate: stopping backup timers to freeze the repo"
        systemctl stop nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer nextcloud-sync.service 2>/dev/null || true

        install -d -o ${ncUser} -g ${ncUser} -m 0700 "$DEST_REPO"
        echo "restic-migrate: copying $SRC_REPO -> $DEST_REPO"
        ${pkgs.rsync}/bin/rsync -a "$SRC_REPO/" "$DEST_REPO/"
        if [ -s "$SRC_PASS" ]; then
          install -m 0600 "$SRC_PASS" "$DEST_PASS"
        fi

        echo "restic-migrate: verifying the copied repo"
        OLD_N="$(env RESTIC_REPOSITORY="$SRC_REPO" RESTIC_PASSWORD_FILE="$SRC_PASS" \
          ${restic}/bin/restic snapshots --compact 2>/dev/null \
          | grep -cE '^[0-9a-f]{8}' || true)"
        NEW_N="$(env RESTIC_REPOSITORY="$DEST_REPO" RESTIC_PASSWORD_FILE="$DEST_PASS" \
          ${restic}/bin/restic snapshots --compact \
          | grep -cE '^[0-9a-f]{8}' || true)"
        [ "$OLD_N" = "$NEW_N" ] \
          || { echo "restic-migrate: snapshot count mismatch ($OLD_N -> $NEW_N) — source kept; investigate" >&2; exit 1; }
        echo "restic-migrate: verified $NEW_N snapshots readable from the pool repo"

        chown -R ${ncUser}:${ncUser} "$DEST_REPO" "$DEST_PASS" 2>/dev/null || true
        mv "$SRC_REPO" "''${SRC_REPO}.pre-zfs-$TS"
        [ -e "$SRC_PASS" ] && mv "$SRC_PASS" "''${SRC_PASS}.pre-zfs-$TS" || true
        echo "restic-migrate: done — legacy repo kept at ''${SRC_REPO}.pre-zfs-$TS (delete once happy)"

        systemctl start nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer 2>/dev/null || true
      '';

      # repair: peel the duplicate archive mount layers the pre-fix bind unit
      # stacked (32 deep at the datadir path and 32 at the dataset's own
      # mountpoint on the real host, Nov 2026). Every layer is the SAME
      # dataset, so nothing here is destructive — the bottom layer is kept.
      # Idempotent: a healthy host (one layer each) is a no-op.
      ncArchiveUnstack = pkgs.writeShellScriptBin "nc-archive-unstack" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        WHERE="${archiveBindWhere}"
        ARCHIVE="${archiveSource}"
        DS="${archiveDataset}"

        zfs list -H -o name "$DS" >/dev/null 2>&1 \
          || { echo "unstack: $DS is gone (retired) — nothing to peel"; exit 0; }

        # mount entries at the dataset's own mountpoint (no spaces in that path,
        # so a field-2 match against /proc/self/mounts is exact)
        layers() { awk -v p="$ARCHIVE" '$2 == p { n++ } END { print n+0 }' /proc/self/mounts; }

        # 1) the datadir bind: peel every layer (umount removes the top one).
        #    The layers are peers of one shared propagation group, so a plain
        #    umount tries to detach every peer at once and fails EBUSY when any
        #    one is held (a shell cd'ed in, NC serving from it). Break the
        #    group first; lazy umount as the last resort.
        n=0
        while findmnt -no SOURCE "$WHERE" >/dev/null 2>&1; do
          mount --make-private "$WHERE" 2>/dev/null || true
          umount "$WHERE" 2>/dev/null || umount -l "$WHERE" 2>/dev/null \
            || { echo "unstack: $WHERE is busy — cd out of it (and stop nextcloud-fpm/nextcloud-cron) and rerun" >&2; exit 1; }
          n=$((n + 1))
        done
        echo "unstack: removed $n bind layer(s) at $WHERE"

        # 2) the dataset's own mountpoint: peel duplicates, KEEP the bottom one
        #    (unmounting the last would detach the archive from the host)
        m=0
        while [ "$(layers)" -gt 1 ]; do
          mount --make-private "$ARCHIVE" 2>/dev/null || true
          umount "$ARCHIVE" 2>/dev/null || umount -l "$ARCHIVE" 2>/dev/null \
            || { echo "unstack: $ARCHIVE is busy — something is inside it; rerun once clear" >&2; exit 1; }
          m=$((m + 1))
        done
        echo "unstack: removed $m duplicate layer(s) at $ARCHIVE"

        findmnt -no SOURCE "$ARCHIVE" | grep -qx "$DS" \
          || { echo "unstack: $DS is not mounted at $ARCHIVE — re-mount with 'zfs mount $DS'" >&2; exit 1; }
        [ "$(layers)" = 1 ] \
          || { echo "unstack: $ARCHIVE still has $(layers) layers" >&2; exit 1; }
        echo "unstack: $DS mounted once at $ARCHIVE; datadir bind cleared"
      '';

      zfsSnapdirVisible = pkgs.writeShellScriptBin "zfs-snapdir-visible" ''
        set -euo pipefail
        [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
        export PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

        # Display-only change: each dataset's historical snapshots become
        # visible at <mountpoint>/.zfs/snapshot. They auto-mount read-only on
        # access; this neither creates snapshots nor mounts them all at once.
        N=0
        for ds in ${zfsPoolPrimary}/nextcloud ${replicaDataset} ${resticDataset} ${resticReplica}; do
          if zfs list -H -o name "$ds" >/dev/null 2>&1; then
            zfs set snapdir=visible "$ds"
            MP="$(zfs get -H -o value mountpoint "$ds")"
            printf '%-30s snapdir=%s  %s/.zfs/snapshot\n' "$ds" "$(zfs get -H -o value snapdir "$ds")" "$MP"
            N=$((N + 1))
          else
            echo "skip $ds (not present)"
          fi
        done
        [ "$N" -gt 0 ] || { echo "no configured ZFS datasets present" >&2; exit 1; }
        echo "snapshots are visible under each dataset's .zfs/snapshot (read-only, auto-mounted on access)"
      '';

      zfsCheck = pkgs.writeShellScriptBin "zfs-check" ''
        set -euo pipefail
        echo "== zpool status =="
        zpool status -v 2>/dev/null | head -24 || true
        echo "== datasets =="
        zfs list 2>/dev/null || true
        echo "== snapshot policy (Sanoid GFS, nextcloud) =="
        echo "hourly=${zfsKeepHourly} daily=${zfsKeepDaily} weekly=${zfsKeepWeekly} monthly=${zfsKeepMonthly}"
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
        Environment="PATH=${ncToolsEnv}/bin:/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ExecStart=${ncProvisionJob}/bin/nc-provision
        TimeoutStartSec=10min
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=${ncRoot} ${backupRoot}
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
      '';

    in
    {
      packages.${system} = {
        inherit occ deploy;
        "apply-config" = applyConfigTool;
        "nc-backup" = ncBackupJob;
        "nc-restore" = ncRestoreJob;
        "nc-provision" = ncProvisionJob;
        "drives-mount" = drivesMount;
        "drives-umount" = drivesUmount;
        "drives-check" = drivesCheck;
        "zfs-install" = zfsInstall;
        "zfs-rehearse" = zfsRehearse;
        "zfs-disaster-mirror-create" = zfsDisasterCreate;
        "zfs-disaster-mirror-check" = zfsDisasterCheck;
        "zfs-disaster-mirror-remove" = zfsDisasterRemove;
        "nc-data-sync-purge" = ncDataSyncPurge;
        "zfs-create-primary" = zfsCreatePrimary;
        "zfs-create-backup" = zfsCreateBackup;
        "zfs-replicate" = zfsReplicate;
        "zfs-verify-migration" = zfsVerifyMigration;
        "zfs-restic-migrate" = zfsResticMigrate;
        "nc-import-archive" = ncImportArchive;
        "nc-archive-share" = ncArchiveShare;
        "nc-archive-retire" = ncArchiveRetire;
        "nc-archive-unstack" = ncArchiveUnstack;
        "nc-transcode-unplayable" = ncTranscodeUnplayable;
        "zfs-check" = zfsCheck;
        "zfs-snapdir-visible" = zfsSnapdirVisible;
        "provisioned-passwords" = zfsProvisionedPasswords;
        nextcloud = nc;
        php = phpEnv;
        postgresql = pg;
        ffmpeg = pkgs.ffmpeg;
        p7zip = pkgs.p7zip;
        redis = pkgs.redis;
        files-archive-app = pkgs.fetchurl {
          url = "https://github.com/rotdrop/nextcloud-app-files-archive/releases/download/v1.3.2/files_archive-1.3.2.tar.gz";
          hash = "sha256-3pXkwvQ1O8+CajdXLzIcV/X7E7U85yCrKbKXgwAmJXw=";
        };
        ebookreader-app = ebookReaderApp;
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
                ${dbInit} \
                ${dbReady} \
                ${initScript} \
                "${zfsInstall}/bin/zfs-install" \
                "${zfsRehearse}/bin/zfs-rehearse" \
                "${zfsDisasterCreate}/bin/zfs-disaster-mirror-create" \
                "${zfsDisasterCheck}/bin/zfs-disaster-mirror-check" \
                "${zfsDisasterRemove}/bin/zfs-disaster-mirror-remove" \
                "${ncDataSyncPurge}/bin/nc-data-sync-purge" \
                "${zfsCreatePrimary}/bin/zfs-create-primary" \
                "${zfsCreateBackup}/bin/zfs-create-backup" \
                "${zfsReplicate}/bin/zfs-replicate" \
                "${zfsVerifyMigration}/bin/zfs-verify-migration" \
                "${zfsResticMigrate}/bin/zfs-restic-migrate" \
                "${ncImportArchive}/bin/nc-import-archive" \
                "${ncArchiveShare}/bin/nc-archive-share" \
                "${ncArchiveRetire}/bin/nc-archive-retire" \
                "${ncArchiveUnstack}/bin/nc-archive-unstack" \
                "${ncTranscodeUnplayable}/bin/nc-transcode-unplayable" \
                "${zfsCheck}/bin/zfs-check" \
                "${zfsSnapdirVisible}/bin/zfs-snapdir-visible" \
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
