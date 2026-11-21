units := "nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init nextcloud-cron.service nextcloud-cron.timer nextcloud-backup.timer nextcloud-snapshot.timer nextcloud-data-sync.timer"
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

# mirror user data/ to dataSyncTarget now (hourly timer also does this)
sync-data:
    sudo systemctl start --wait nextcloud-data-sync.service

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

# layer-A test harness: full lifecycle in a disposable systemd container
# (safe next to production — separate systemd instance). Scenarios: install | full | reset
test-docker scenario="install":
    tests/docker-run.sh {{ scenario }}

# mirror overview: sizes, file counts, last syncs, preserved deletions
mirror-list:
    nix run .#nc-data-sync -- status

# compare live data/ vs mirror — quick counts; mirror-check deep = authoritative
mirror-check deep="":
    #!/usr/bin/env bash
    if [ "{{ deep }}" = "deep" ]; then
      nix run .#nc-data-sync -- compare-deep
    else
      nix run .#nc-data-sync -- compare-quick
    fi

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
    $SUDO systemctl stop nextcloud-backup.timer nextcloud-snapshot.timer
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
      journalctl -f -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-data-sync
    else
      journalctl -f -u "{{ unit }}"
    fi

# recent logs of the stack (or one unit + count: just logs nextcloud-init 200)
logs unit="all" lines="80":
    #!/usr/bin/env bash
    if [ "{{ unit }}" = "all" ]; then
      journalctl -n {{ lines }} --no-pager --full \
        -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron \
        -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-data-sync
    else
      journalctl -u "{{ unit }}" -n {{ lines }} --no-pager --full
    fi

# only errors/failures from the last 24h for all units
errors:
    #!/usr/bin/env bash
    journalctl --no-pager --full -p err --since "24 hours ago" \
      -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron \
      -u nextcloud-backup -u nextcloud-snapshot -u nextcloud-data-sync

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
        -u nextcloud-db -u nextcloud-fpm -u nextcloud-caddy -u nextcloud-init -u nextcloud-cron
      echo
      echo "## php slowlog (requests > 10s)"
      sudo -n cat /var/lib/nextcloud/php-slow.log 2>/dev/null | tail -n 80 || \
        { echo "== needs sudo to read the slowlog; run manually: just slowlog"; }
    } > "$out"
    echo "wrote $out  ($(wc -l < "$out") lines)"
