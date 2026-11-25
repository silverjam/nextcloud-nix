units := "nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init nextcloud-cron.service nextcloud-cron.timer nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.service nextcloud-sync.timer nextcloud-provision.service"
port := "55555"  # keep in sync with webPort in flake.nix

# available tasks
@default:
    @just --list

# deploy/update the stack (build from flake, install units, restart services; asks for sudo)
deploy:
    nix run .#deploy

# full backup now: db dump + app state, consistent (brief maintenance:mode)
backup:
    sudo systemctl start --wait nextcloud-backup.service

# incremental snapshot now: db dump + app state, no downtime
snapshot:
    sudo systemctl start --wait nextcloud-snapshot.service

# apply provisionedUsers (declarative user creation; also runs per deploy)
provision:
    sudo systemctl start --wait nextcloud-provision.service

# ZFS migration phase 0: install tooling + ARC cap (safe; no drives needed)
zfs-install:
    nix run .#zfs-install

# ZFS migration phase 0: rehearse the whole lifecycle on throwaway loop pools
zfs-rehearse:
    nix run .#zfs-rehearse

# connect the two NTFS volumes READ-ONLY at /mnt/primary + /mnt/backup
# (migration-only mounts; nothing in the migration writes to them)
drive-mount:
    nix run .#drives-mount
drive-umount:
    nix run .#drives-umount
drive-check:
    nix run .#drives-check

# phase 0.5: full local disaster mirror of sdc1 onto the root disk
zfs-disaster-mirror-create:
    nix run .#zfs-disaster-mirror-create
zfs-disaster-mirror-check:
    nix run .#zfs-disaster-mirror-check
zfs-disaster-mirror-remove:
    nix run .#zfs-disaster-mirror-remove

# phase 2/3 (DESTRUCTIVE — both require a typed CONFIRM)
zfs-create-primary:
    nix run .#zfs-create-primary
zfs-create-backup:
    nix run .#zfs-create-backup

# ongoing: Sanoid GFS snapshots + Syncoid replication (primary -> backup pool)
sync-data:
    nix run .#zfs-replicate

# status: pools, datasets, snapshots, mounts, migration stamps
zfs-check:
    nix run .#zfs-check

# make ZFS snapshots visible at <mountpoint>/.zfs/snapshot (display-only)
snapshots-visible:
    nix run .#zfs-snapdir-visible

# final verification of the whole migration (enables disaster-mirror removal)
zfs-verify-migration:
    nix run .#zfs-verify-migration

# move an existing root-disk restic repo onto the ZFS backup pool (idempotent)
zfs-restic-migrate:
    nix run .#zfs-restic-migrate

# DESTRUCTIVE: delete the retired rsync mirror tree (needs CONFIRM=mirror + migration-complete)
nc-data-sync-purge:
    nix run .#nc-data-sync-purge

nc-import-archive:
    nix run .#nc-import-archive

nc-archive-share:
    nix run .#nc-archive-share

nc-archive-retire:
    nix run .#nc-archive-retire

# repair: peel duplicate archive mount layers (bind stack / duplicate dataset mounts)
nc-archive-unstack:
    nix run .#nc-archive-unstack

nc-transcode-unplayable:
    nix run .#nc-transcode-unplayable

# show the one-shot passwords generated for provisioned users (optional uid filter)
provisioned-passwords uid="":
    nix run .#provisioned-passwords -- {{ uid }}

# list restic snapshots (+ sizes)
backup-list:
    nix run .#nc-backup -- list

# fast validation: latest db dump is readable (extract + TOC check)
backup-validate:
    nix run .#nc-backup -- validate

# deep validation: full pg_restore of latest dump into a scratch db (dropped after)
backup-validate-deep:
    nix run .#nc-backup -- validate-deep

# verify repo integrity (reads metadata; may be slow)
backup-check:
    nix run .#nc-backup -- check

# apply retention policy manually (also runs after the daily full)
backup-prune:
    nix run .#nc-backup -- prune

# restore an archive (db + files): just restore latest | just restore <id>
restore *args:
    nix run .#nc-restore -- {{ args }}

# container test harness: full lifecycle in a disposable systemd container
# (safe next to production — separate systemd instance). Scenarios: install | full | reset
test-docker scenario="install":
    tests/docker-run.sh {{ scenario }}

# vm test harness: REAL Ubuntu VM (qemu/kvm + cloud-init) — cold boot, reboot
# persistence, same scenarios + reboot. First run downloads ~1GB cloud image.
test-vm scenario="install":
    tests/vm-run.sh {{ scenario }}

# install the lefthook binary (nix profile; idempotent up/downgrades)
hooks-install:
    nix profile add .#lefthook

# wire the pre-commit hook into this repo's .git (run after each fresh clone;
# needs the lefthook binary — run `just hooks-install` once per machine)
hooks-setup:
    nix run .#lefthook -- install
    test -f .git/hooks/pre-commit && echo "pre-commit hook wired — next commit runs flake-check + shellcheck + just-syntax"

# everything the pre-commit hook runs, without needing a git commit
# (--all-files neutralizes lefthook's staged-files scoping)
check:
    nix run .#lefthook -- run pre-commit --all-files

# point https://<tailnet>.ts.net at Nextcloud via tailscale serve
tailscale:
    #!/usr/bin/env bash
    set -euo pipefail
    TS_NAME="$(tailscale status --json 2>/dev/null | grep -oE '"DNSName": "[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')"
    if [ -z "$TS_NAME" ]; then
      echo "could not detect this node's tailnet DNS name (logged out or MagicDNS disabled?)" >&2
      exit 1
    fi
    echo "== https://$TS_NAME -> http://127.0.0.1:{{ port }} =="
    # replaces any previous serve rule for this node (e.g. the old :8080 one)
    sudo tailscale serve --bg --https=443 http://127.0.0.1:{{ port }}

    echo "== trusted_domains[3] = $TS_NAME =="
    nix run .#occ -- config:system:set trusted_domains 3 --value "$TS_NAME"
    echo "== trusted_proxies[0] = 127.0.0.1 (so X-Forwarded-* is honoured) =="
    nix run .#occ -- config:system:set trusted_proxies 0 --value 127.0.0.1

    echo "== certificate check (first issue can take a few seconds) =="
    ok=""
    for i in $(seq 1 8); do
      if curl -fsS --max-time 15 "https://$TS_NAME/status.php" | grep -q installed; then
        ok=1; break
      fi
      sleep 2
    done
    if [ -n "$ok" ]; then
      echo "OK — open https://$TS_NAME on any device in your tailnet"
    else
      echo "WARN: https not verified yet. Check 'sudo tailscale serve status' and enable" >&2
      echo "'HTTPS Certificates' + MagicDNS in the tailnet admin console (tailscale.com/admin/dns)." >&2
    fi

# undo tailscale HTTPS fronting
tailscale-off:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo tailscale serve reset
    nix run .#occ -- config:system:delete trusted_proxies || true
    echo "serve rules cleared (trusted_domains entry left in place — harmless)"

# wipe ALL Nextcloud data (config, user files, db cluster) and reinstall fresh
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "⚠  This deletes ALL Nextcloud data:"
    echo "   /var/lib/nextcloud       config, admin password, user files"
    echo "   /var/lib/nextcloud-db    the entire database cluster"
    echo "and then re-runs the first-time install (new admin password)."
    if [ "${FORCE:-0}" != "1" ]; then
      read -r -p "Type RESET to continue: " ans
      [ "$ans" = "RESET" ] || { echo "aborted"; exit 1; }
    fi
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO=sudo
    echo "== stopping services =="
    $SUDO systemctl stop nextcloud-fpm nextcloud-caddy nextcloud-cron.timer nextcloud-cron.service nextcloud-init
    $SUDO systemctl stop nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-sync.timer nextcloud-sync.service
    $SUDO systemctl stop nextcloud-db
    echo "== deleting data =="
    $SUDO rm -rf /var/lib/nextcloud /var/lib/nextcloud-db
    echo "== reinstalling =="
    nix run .#deploy

# active/failed state of every unit (fast one-liner view)
state:
    #!/usr/bin/env bash
    for u in {{ units }}; do
      s="$(systemctl is-active "$u")"
      note=""
      [ "$u" = "nextcloud-cron.service" ] && note=" (oneshot — triggered by its timer)"
      printf '%-22s %s%s\n' "$u" "$s" "$note"
    done

# status detail of the stack (or one unit: just status nextcloud-fpm)
# note: systemctl status exits non-zero for inactive/failed units — tolerated
status *unit_args:
    #!/usr/bin/env bash
    systemctl --no-pager --full status {{ if unit_args == "" { units } else { unit_args } }} || true

# follow stack logs live (or one unit: just follow nextcloud-caddy)
follow unit="all":
    #!/usr/bin/env bash
    if [ "{{ unit }}" = "all" ]; then
      journalctl -f -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-sync
    else
      journalctl -f -u "{{ unit }}"
    fi

# recent logs of the stack (or one unit + count: just logs nextcloud-init 200)
logs unit="all" lines="80":
    #!/usr/bin/env bash
    if [ "{{ unit }}" = "all" ]; then
      journalctl -n {{ lines }} --no-pager --full \
        -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron \
        -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-sync
    else
      journalctl -u "{{ unit }}" -n {{ lines }} --no-pager --full
    fi

# only errors/failures from the last 24h for all units
errors:
    #!/usr/bin/env bash
    journalctl --no-pager --full -p err --since "24 hours ago" \
      -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron \
      -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-sync

# php stack traces of requests that ran >10s (see php-fpm slowlog)
slowlog:
    #!/usr/bin/env bash
    sudo sh -c 'tail -n 120 /var/lib/nextcloud/php-slow.log 2>/dev/null || echo "(no slow requests logged yet)"'

# write a debugging bundle (state + failing-unit detail + recent journal) to ./log
dump lines="120":
    #!/usr/bin/env bash
    set -euo pipefail
    out=./log
    {
      echo "# nextcloud stack log dump — $(date -Is) — $(hostname)"
      for u in {{ units }}; do
        printf '%-22s %s\n' "$u" "$(systemctl is-active "$u")"
      done
      echo
      for u in {{ units }}; do
        if [ "$(systemctl is-active "$u")" != "active" ]; then
          echo "## $u (not active) — unit status, last {{ lines }} lines"
          { systemctl --no-pager --full status "$u" | sed -n '1,14p'; } || true
          journalctl -u "$u" -n {{ lines }} --no-pager --full
          echo
        fi
      done
      echo "## combined journal — last {{ lines }} lines"
      journalctl -n {{ lines }} --no-pager --full \
        -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron \
        -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-sync
      echo
      echo "## php slowlog (requests > 10s)"
      sudo -n cat /var/lib/nextcloud/php-slow.log 2>/dev/null | tail -n 80 || \
        { echo "== needs sudo to read the slowlog; run manually: just slowlog"; }
    } > "$out"
    echo "wrote $out  ($(wc -l < "$out") lines)"
