# Nextcloud via Nix — PostgreSQL + PHP-FPM + Caddy

A Nix-deployed personal Nextcloud for this Ubuntu host. **No containers, no NixOS** —
Nix builds every binary/config (PHP with extensions, PostgreSQL, Nextcloud itself,
Caddy) into the immutable store, and plain systemd units run them.

```
flake.nix ──nix build──▶ /nix/store/…-nextcloud-34.0.6   (webroot, incl. occ)
                        /nix/store/…-php-with-extensions (CLI + php-fpm)
                        /nix/store/…-postgresql-17.12
                        /nix/store/…-caddy + generated Caddyfile
                        /nix/store/…*.service/.timer units + bootstrap scripts
                        │
                        ▼  nix run .#deploy (copies units, enables & starts)
   systemd ──▶ nextcloud-db (postgres, unix-socket only, peer auth)
            ─▶ nextcloud-fpm (php-fpm pool → /run/nextcloud/php-fpm.sock)
            ─▶ nextcloud-caddy (port 55555 → webroot + fastcgi)
            ─▶ nextcloud-init (oneshot: db, install, config.php)
            ─▶ nextcloud-cron.timer (background jobs every 5 min)
```

## Data locations

| Path | What |
|---|---|
| `/var/lib/nextcloud` | Nextcloud state: `data/` (user files), `config/config.php`, `store-apps/` |
| `/var/lib/nextcloud-db` | PostgreSQL 17 data directory |
| `/var/lib/nc-caddy` | Caddy TLS/storage state |
| `/run/nextcloud-db`, `/run/nextcloud` | Unix sockets (postgres, php-fpm) |

Postgres only listens on a Unix socket — no TCP. Two local auth paths in
`pg_hba.conf`: the `nextcloud` bootstrap/admin role uses OS **peer** auth (no
passwords stored anywhere), while the minimal `oc_*` app role that the
Nextcloud installer creates authenticates with a **scram-sha-256 password**
that the installer generates itself (stored in `config.php`) — scoped by a
user-name regex (`/^oc_`) in `pg_hba.conf` so the scram rule can never
shadow peer auth. The app role is a plain LOGIN role — deliberately not a
superuser. Caddy runs as its own
`nc-caddy` user and is the only component reachable from the network.

## Daily use

```bash
# install / update the whole stack (self-elevates via sudo)
just deploy                # (== nix run .#deploy)
```

### just tasks (logs & debugging)

```bash
just state                 # one-line active/failed view of every unit
just status                # full status of the stack   (or: just status nextcloud-fpm)
just follow                # live-follow all stack logs (or: just follow nextcloud-caddy)
just logs nextcloud-init   # last N lines of one unit   (just logs nextcloud-init 200)
just errors                # error-severity entries of the last 24h
just dump                  # write state + failing-unit detail + journal to ./log
```

`just dump` writes exactly the file worth attaching when reporting "start failed".

```bash
# administer via the occ CLI (runs as the right user)
nix run .#occ -- status
nix run .#occ -- user:add alice

# logs
journalctl -u nextcloud-fpm -f        # php app errors
journalctl -u nextcloud-caddy         # web server
journalctl -u nextcloud-db            # database

# background job manual run
nix run .#occ -- background:cron
```

- **URL:** `http://localhost:55555/` — trusted domains are auto-set to
  `localhost`, your hostname, and your primary LAN IP. For any other name/IP:
  `nix run .#occ -- config:system:set trusted_domains 3 --value <ip-or-name>`
- **Admin login:** `admin`, password at `/var/lib/nextcloud/admin-password`
  (generated on first install, mode 0600): `sudo cat /var/lib/nextcloud/admin-password`
- **Firewall:** deploy auto-opens `55555/tcp` in ufw when ufw is active.

## Upgrades

Nextcloud forbids skipping major versions, so bump one major at a time:

```bash
nix run .#occ -- maintenance:mode --on
nix flake update                 # or edit the pin in flake.nix
nix run .#deploy
nix run .#occ -- upgrade         # runs DB/app migrations
nix run .#occ -- maintenance:mode --off
```

For everyday security updates re-running `nix flake update && nix run .#deploy`
is enough (same major ⇒ no manual `upgrade` needed, deploy restarts everything).

PostgreSQL major-version bumps (pin `pg = pkgs.postgresql_17` in `flake.nix`)
need a dump/restore or `pg_upgrade` — don't just rebuild:

```bash
nix run .#occ -- maintenance:mode --on
sudo -u nextcloud $(nix path-info .#packages.x86_64-linux.postgresql)/bin/pg_dump \
    -h /run/nextcloud-db -U nextcloud nextcloud > backup.sql
# stop stack, rebuild with new pg, re-init /var/lib/nextcloud-db, psql < backup.sql
```

## Editing the deployment

Everything lives in `flake.nix` (single source of truth: users, paths, ports,
upload size via `phpIniExtra`, Caddyfile, units). After any edit:

```bash
nix run .#occ -- maintenance:mode --on   # optional for web-visible changes
nix run .#deploy
```

Common tweaks:
- **Upload size:** `phpIniExtra` (`upload_max_filesize`, `post_max_size`) and
  `request_body.max_size` in the Caddyfile
- **PHP pool size:** `phpFpmConf` `pm.max_children`

### Tailscale HTTPS (real certs your phone accepts, zero ACME config)

Prerequisites (one-time):
```bash
curl -fsSL https://tailscale.com/install.sh | sh   # already installed on this host
sudo tailscale up                                  # log in; MagicDNS enabled
# tailnet admin console → DNS → "HTTPS Certificates" enabled
```

Then:
```bash
just tailscale        # https://<node>.ts.net → Caddy (:55555), sets trusted_domains
                      # and 127.0.0.1 as trusted proxy (X-Forwarded-Proto is how
                      # NC switches to https through the tailnet only)
just tailscale-off    # undo (clears serve rules; trusted_domains stays, harmless)
```

The cert for `<node>.<tailnet>.ts.net` is publicly trusted (Let's Encrypt, issued
by tailscaled automatically) — no custom CA on clients. LAN access over plain
HTTP keeps working; nothing changes for caddy or the Nix config.

## Uninstall

```bash
sudo systemctl disable --now nextcloud-db nextcloud-fpm nextcloud-caddy nextcloud-init nextcloud-cron.timer
sudo rm /etc/systemd/system/nextcloud-{db,fpm,caddy,init,cron}.{service,timer}
sudo systemctl daemon-reload
sudo userdel nextcloud nc-caddy            # only if you want the users gone
sudo rm -rf /var/lib/nextcloud /var/lib/nextcloud-db /var/lib/nc-caddy
```

## Backups & restore (restic) — db + app state

Archives contain the **PostgreSQL dump** (`pg_dump --format=custom`) plus the
**app state** outside the data dir: `config/` (config.php), `store-apps/`,
`admin-password`, and the restic passphrase file. Restores rebuild the `oc_*`
DB role from the archived `config.php`, so an archive restores correctly even
onto a fresh instance.

**User file data (`/var/lib/nextcloud/data`) is deliberately NOT in these
archives.** It's mirrored separately by `nextcloud-data-sync.timer` (hourly,
rsync to `dataSyncTarget` — default `/var/backups/nextcloud/data`, change one
line in flake.nix to point at another mounted volume; set `""` to disable).
The mirror is deletion-safe: removed/overwritten files are kept in
`<target>/.trash/<date>` for 30 days (`dataSyncTrashDays`), and regenerable
caches (`nextcloud.log`, preview thumbnails) are skipped. Same-disk mirrors
protect against mistakes, not disk death — point the target at another
volume for that.

- **Full** (daily 03:00, `nextcloud-backup.timer`): flips `maintenance:mode`
  on for the duration, prunes old snapshots by retention afterwards.
- **Incremental** (`nextcloud-snapshot.timer`, hourly): same contents with no
  downtime. "Incremental" = restic chunk-dedup across consecutive dumps (only
  changed DB blocks get stored); a true WAL-archiving/PITR setup is the
  follow-up if you need minute-level DB recovery.
- Retention (in flake.nix): hourly ×24, daily ×14, weekly ×6, monthly ×6.
- Repo: `/var/backups/nextcloud/repo` (restic repos are always encrypted;
  the machine-managed passphrase is auto-generated at
  `/var/backups/nextcloud/.restic-pass`, mode 0600 — keep it with the repo,
  restores need it).

```bash
just backup                 # full now (brief maintenance:mode)
just snapshot               # incremental now (no downtime)
just sync-data              # mirror data/ to dataSyncTarget now (hourly timer)
just backup-list            # snapshots, ids, dedup size
just backup-validate        # latest dump readable? (extract + pg_restore TOC)
just backup-validate-deep   # latest dump FULLY restores? (scratch db, dropped)
just backup-check           # repo integrity (manual, may be slow)
just backup-prune           # apply retention manually

just mirror-list            # data/ mirror overview + last syncs
just mirror-check           # live vs mirror counts (quick)
just mirror-check deep      # authoritative rsync dry-run diff

just restore                # latest archive — interactive confirm (type RESTORE)
just restore <snapshot-id>  # or FORCE=1 just restore <id>
```

Restore behavior has two modes:

- **State-only archives (what the timers produce now):** services stop → DB
  dropped/recreated + `pg_restore` → `config/`, `store-apps/`, admin password
  restored — **existing `data/` user files are left untouched**. Note that
  restoring an *older* DB next to a *newer* `data/` can make recently uploaded
  files "unlisted" (they're on disk, unknown to the DB until re-uploaded or
  `occ files:scan --all`).
- **Data-including archives (older ones from before the scope change):** full
  restore — everything including `data/` is swapped in from the archive; the
  previous state is moved aside, never deleted:
  `/var/lib/nextcloud.pre-restore-<ts>` (respectively `config.pre-restore-<ts>`
  in state-only mode). Deleting those is manual and yours.

Restoring onto a **fresh host**: run `nix run .#deploy` first (users + units),
copy `/var/backups/nextcloud` over, then `just restore <id>`.

Off-box later: point `RESTIC_REPOSITORY` at an ssh/S3 target in the flake —
repos are format-compatible; `just backup-list` works identically remote.

## Testing

- **Layer F (static, always):** `nix flake check` — Caddyfile validation, PHP
  env + extension assertions, `shellcheck -S error` over every generated
  script, PHP lint of the config writer. Unit-file verification (`systemd-analyze
  verify`) runs inside the container harness, where Ubuntu's systemd matches
  production.
- **Layer A (container harness):** `just test-docker` — boots Ubuntu 26.04 with
  real systemd as PID 1 in a privileged container, installs multi-user Nix
  (cached in the `nc-test-nix` volume), mounts this repo read-only, and runs
  `nix run .#deploy` there. Scenarios: `install` (fresh deploy + units +
  `status.php` + real CSRF login), `full` (seed file via data dir + scan,
  db/app-state snapshot + `validate-deep`, corrupt config.php → `restore`
  roundtrip with `data/` untouched, post-restore login), `reset`
  (`just reset` determinism). The container's systemd is separate from the
  host's, so unit names, ports and `/var/lib` cannot collide with production.
  `NC_TEST_KEEP=1 just test-docker ...` keeps the container for debugging;
  `NC_TEST_REBUILD=1` refreshes the systemd base image.
- **Layer C (planned):** QEMU + cloud-init Ubuntu VM for cold boots, reboots,
  the nixpkgs-upgrade matrix and real tailscale.

## Full reset (deletes all instance data)

```bash
just reset          # stops services, wipes everything, reinstalls, prints new admin password
FORCE=1 just reset  # same, without the confirmation prompt
```

`just reset` removes `/var/lib/nextcloud` (config, user files, admin password)
and `/var/lib/nextcloud-db` (the database cluster — the NC app role and its
grants live inside the cluster, so rebuilding it keeps the auth model simple).

## Notes

- `nextcloud-init` is never destructive: it creates the database if missing,
  tidies roles left by aborted installs (only while no instance is installed),
  and runs the install until `config.php` appears. If you want a blank-slate
  instance, `just reset` does that explicitly.

- The webroot and all binaries are immutable store paths; the instance is fully
  reproducible from `flake.nix` + `flake.lock` (`nix flake check` validates the
  Caddyfile and PHP env).
- `config.php` at `/var/lib/nextcloud/config/config.php` is user-owned; the
  init unit re-applies a few nix-owned keys on every deploy (app store path,
  APCu caching) — everything else you set (via occ or web UI) is kept.
- Version pins live at the top of `flake.nix`: currently nextcloud **34.0.6**
  (35 is also built in this nixpkgs), php **8.4**, postgres **17**, caddy **2.11**.
