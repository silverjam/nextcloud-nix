# Nextcloud via Nix — PostgreSQL + PHP-FPM + Caddy

[![CI](https://github.com/silverjam/nextcloud-nix/actions/workflows/ci.yml/badge.svg)](https://github.com/silverjam/nextcloud-nix/actions/workflows/ci.yml)

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

**Pre-commit checks** (lefthook): run once per machine `just hooks-install`
(binary into your nix profile) and once per clone `just hooks-setup`. Every
`git commit` then runs `nix flake check` (output only on failure),
shellcheck over `tests/`, and justfile syntax (≈4s once the store is warm).
Run the same set on demand with `just check` (no git needed).
Escape hatches: `git commit --no-verify` or `LEFTHOOK=0 git commit …`.
Hook auto-skips during rebase/merge. Note the check evaluates the working
tree, not only the staged files.

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

All four upgrade kinds are rehearsed 1:1 by test scenarios — whatever the
walkthrough below says, `just test-docker <scenario>` (or `just test-vm …`)
executes exactly that sequence against a disposable instance. Nextcloud
forbids skipping major versions: always one major at a time.

### PostgreSQL — minor (e.g. 17.11 → 17.12)

**How it works:** minor releases are drop-in compatible — the data directory
is not touched, postgres rewrites nothing, there are no migrations. The
upgrade is a binary + library swap followed by an in-place restart.

```bash
nix flake update        # moves the pin (rides along with other updates)
just deploy             # pg restarts on the new binary; datadir survives
```

Verify: `nix run .#postgresql -- --version` (expect 17.12+), `just backup-list`
(take a fresh snapshot), and the instance is healthy — no `occ upgrade`
involved, DB schema is untouched by design.

**Drill:** `test-docker upgrade-pg-minor` pins nixpkgs at the parent of the
real bump commit (`postgresql_17: 17.11 -> 17.12`), deploys the old tree,
seeds a DB marker + file, then redeploys the current tree and asserts the
marker, the file, the login and that `validate-deep` succeeds *under the new
binary*. Also proves that a flake update rides pg and Nextcloud patches
together (a real update moves both).

### PostgreSQL — major (17 → 18)

**How it works:** major versions have incompatible data directories. The 18
binary *refuses to start* on a 17 cluster — this is expected and why the db
unit fails by design during this migration. The database travels via the
`pg_dump` inside a full archive.

```bash
# 0. plan a downtime window (backup + rebuild + restore)
nix run .#occ -- maintenance:mode --on

# 1. the migration vehicle: a full archive (validated BEFORE touching anything)
nix run .#nc-backup -- full
nix run .#nc-backup -- validate-deep

# 2. flip the pin in flake.nix:  pg = pkgs.postgresql_18;
just deploy                     # db unit FAILS here — expected
# (also expected: the deploy aborts mid-way, because init cannot work with
#  an empty database and an existing config.php — the restore heals it)

# 3. fresh 18 cluster
sudo systemctl stop nextcloud-*.timer nextcloud-*.service nextcloud-db
rm -rf /var/lib/nextcloud-db
just deploy                     # db re-initialized by pg 18; init may fail again
                                # (existing config.php + empty db is not
                                #  installable) — the restore heals this

# 4. bring the database back from the archive
sudo -E env "PATH=$PATH" just restore latest || FORCE=1 just restore latest

# 5. clean re-run + verify
just deploy
nix run .#occ -- status         # installed: true, no maintenance
```

**Rollback:** pin back `pg = pkgs.postgresql_17`, wipe the 18 cluster, deploy,
`just restore latest` again — the same archive restores into the old major.
Keep the pre-migration dump until you're confident (the archive is
content-addressed and survives everything except `just reset`).

**Drill:** `test-docker upgrade-pg-major` — full archive on 17 → flip to 18 →
asserts the db unit fails as documented → wipes the cluster → restores →
asserts PG 18.7, marker, seed file, login, and a fresh `validate-deep`
under 18. `nc-restore` leaves the restored instance out of maintenance mode
(full archives snapshot `config.php` during the ON window).

User files (`data/`) are untouched by a db-major migration — only the
database travels.

### Nextcloud — minor (34.0.5 → 34.0.6)

**How it works:** a `nix flake update` moves the patch release. Code is
swapped (new store path mounted), and if that patch set carries any DB
migrations `needsDbUpgrade` flips true until `occ upgrade` runs. DB schema
changes in patch releases are rare and shallow — but run the upgrade anyway.

```bash
nix flake update
just deploy
nix run .#occ -- upgrade        # no-op or shallow; always run it
nix run .#occ -- maintenance:mode --off
```

**Rollback:** pin the previous nixpkgs rev (e.g. revert `flake.lock` with
`git checkout` on an old lock) and redeploy. Nextcloud itself doesn't
support downgrades — if a patch misbehaves, restore from an archive instead
(the drills' `restore-fresh` is that procedure in full).

**Drill:** `test-docker upgrade-nc-minor` pins nixpkgs at the parent of the
real commit `nextcloud34: 34.0.5 -> 34.0.6`, deploys, seeds, then upgrades
and asserts version 34.0.6 with marker + seed file + login intact.

### Nextcloud — major (33 → 34)

**How it works:** a code swap with the next major's *store path* plus DB/app
migrations. Two things the drills discovered and the procedure handles:

1. **chicken-and-egg**: after the code swap, `occ` cannot boot while
   `config.php` still pins the *old store's* `apps_paths` (old-tree apps
   crash the new core — even `occ status`). `nix run .#apply-config`
   re-writes the nix-owned config values *without* booting occ, which is why
   it exists as a standalone tool.
2. **two-phase deploy**: while `needsDbUpgrade` is true, db-occ commands are
   refused — `nextcloud-init` (which runs `db:add-missing-indices`) fails and
   the deploy aborts mid-way. That is expected; the upgrade clears it and the
   deploy re-runs cleanly.

```bash
# 0. third-party apps first: they must support the target major
nix run .#occ -- app:update --all

# 1. safety: full archive + deep validation BEFORE the migration
nix run .#nc-backup -- full
nix run .#nc-backup -- validate-deep

# 2. maintenance window
nix run .#occ -- maintenance:mode --on

# 3. flip the pin in flake.nix:  nc = pkgs.nextcloud35;
just deploy                     # may abort at init — expected (see above)

# 4. de-stale the config, run the migrations
nix run .#apply-config
nix run .#occ -- upgrade        # can take a while; watch with -f on the second:
                                 #   journalctl -u nextcloud-fpm -f
nix run .#occ -- maintenance:mode --off

# 5. clean re-run + verify
just deploy
nix run .#occ -- status         # version: 35.x, installed: true
```

**Rollback:** there is none in-place — Nextcloud DB migrations are one-way.
The rollback is a *restore*: pin the previous nixpkgs rev, `just reset`
(keeps repo + passfile), `just restore latest` with a pre-upgrade archive.
This is why step 1 (full backup + validate-deep) is not optional.

**Drill:** `test-docker upgrade-nc-major` — pins NC 33, deploys, seeds,
then executes steps 3–5 verbatim and asserts version 34.0.6 with marker +
seed file + login intact. For a two-step jump (e.g. 32 → 33 → 34 when
catching up) run the drill machinery per step by pinning the intermediate
nixpkgs tree.

## Storage: migrating to ZFS

The two USB data disks migrate from NTFS to ZFS: sdc1 (label `Data`, 681G) becomes
the pool **`primary`** — the Nextcloud datadir mounts directly on its
`primary/nextcloud` dataset at the existing `/var/lib/nextcloud/data` path (zero
config.php changes); sdb1 (label `Data Backup`) becomes pool **`backup`** — the
replication target seeded via `zfs send/receive`. No fstab entries anywhere:
zfs-import + zfs-mount services handle both. 370G of pre-existing legacy
`Data Backup` content on sdb1 is deliberately **dropped** with the reformat
(decision 2026-11-21).

Safety design: Phase 0.5 (`zfs-disaster-mirror-create`) copies the entire
sdc1 content to the root SSD (`/var/backups/disaster-mirror-sdc1`, ~631GiB,
verified by counts + 250 spot-checksums) — that's the single surviving copy
during the Phase 2 rebuild window (accepted risk: machine-only during those
hours). The legacy sdb1 content lives until Phase 3 wipes it.

```bash
just zfs-install                  # 0: zfsutils + module + 8G ARC cap
just zfs-rehearse                 # 0: lifecycle rehearsal on throwaway loop pools
just drive-mount                  # 0.5 prerequisite: mounts NTFS volumes ro
just zfs-disaster-mirror-create   # 0.5: sdc1 -> root SSD + verification stamp
just drive-umount                 # 2: recipe refuses while a drive is mounted
CONFIRM=primary just zfs-create-primary     # 2: DESTROYS sdc1 NTFS
just zfs-create-backup            # 3: DESTROYS sdb1 NTFS (legacy dropped)
just zfs-restic-migrate           # 3b: move the root-disk restic repo onto primary/restic
just zfs-verify-migration         # certifies pools, datadir, replica
just nc-import-archive            # copy archive into NC + group share (stamps import-complete)
just zfs-disaster-mirror-remove   # LAST: needs import-complete + CONFIRM=disaster — nothing automated
```

Interlocks are stamps under `/var/backups/nextcloud/migration-state/` —
each phase refuses without the previous stamp, and both destructive recipes
demand a typed `CONFIRM`. After Phase 2, `just sync-data` becomes snapshot +
incremental `zfs send/receive` into `backup/nextcloud-data` (48 snapshots
retained), replacing the retired rsync mirror; `just zfs-check` reports pools,
datasets, mounts and the last replication time.

Phase 2 also creates `primary/restic` (mounted at `/var/backups/restic`) — the
dataset the restic repo lives on, so it no longer fills the root SSD. Because
it lives on primary it joins the replication set: the Phase-3 seed and every
`zfs-replicate` run mirror it to `backup/restic`, giving the repo the same
redundancy as the user data. The deploy reconciles the dataset too (for hosts
whose primary pool predates this change), and `just zfs-restic-migrate` copies
an existing root-disk repo onto it (idempotent; the source is kept until the
copy verifies).

### Full-pipeline rehearsal before touching real hardware

`tests/vm-run.sh zfs-drill` runs every recipe above **end-to-end in a QEMU
VM** against throwaway hardware: two loopfile NTFS "drives" (labels `Data` /
`Data Backup`), recipes re-pointed via flake-overrides to the loop devices and
drill pools (`drill-primary`/`drill-backup`), the live Nextcloud datadir
actually moved onto ZFS and back. It exercises the disaster mirror, interlock
stamps, CONFIRM gates, replica seeding, incremental replication, the
migration-complete stamp, and restores the instance afterwards.

- Needs KVM + the ZFS kernel module **inside the guest** (installed by the
  scenario) — runs host-local only; intentionally **not** in the CI matrix
  (GitHub runners have neither KVM guarantees nor the ZFS module).
- The guest kernel owns a separate pool namespace, so drill pools can never
  collide with the real ones; they are destroyed in teardown regardless.
- The drill caught (and the recipes now fix): the sandbox-unbound `MODEL`
  reference and the partition-node `lsblk` MODEL read, NTFS xattr `-X/-A`
  round-trip errors, the literal `backup` pool name in `zfs-create-backup`,
  replica receives inheriting the primary's mountpoints (would have mounted
  the backup copy over the live datadir), an inverted retention prune, and a
  wrong `findmnt` column in `zfs-verify-migration`. Run it again before the
  real migration.

### Archive import (plan of record)

After the migration is verified, the archive is served to Nextcloud in two
steps. **Interim (zero copy): `just nc-archive-share`** — a systemd mount unit
binds the archive dataset into the datadir (after provisioning run the
account, per unit ordering), the recipe scans it and shares the folder with
each member of `parents` (read+change+create+delete, 15) via the owner's OCS
credentials. Per-member user-shares are deliberate: NC 34 silently drops
type-3 group-share recipients, while user-shares carry every parameter.
**Interim limitation**: the bind path is fully browsable/readable through the
web UI, but deleting through it is at view-level only (the physical file
stays on the dataset — data-safe, and it reappears after the next scan);
real cleanup (trash/versions/edit) comes with the option-B copy below, which
uses native NC files. Delete-through-UI moves files into trash (retention
disabled — nothing auto-expires) with the dataset copy untouched. **Long term (option B):
`just nc-import-archive`** copies the archive dataset into the folder of
service user `archive` as `Archive <year>-<year>` (name stamped once from the
oldest file on disk), scans it and shares the same way; resumable (count
stamp + 250-file spot check), stamps `import-complete` when done — after
which the interim bind and its share can be retired. The recipe is
resumable (count stamp + 250-file spot check) and stamps `import-complete`
when done. **`zfs-disaster-mirror-remove` requires that stamp plus a typed
`CONFIRM=disaster` — nothing automated ever invokes it**, and the disaster
mirror intentionally stays on the root SSD as the second copy until the import
is verified.

The interim bind's honest name ("Archive (Read only)") reflects its contract:
deletes through it are view-level only (the physical file stays on the
dataset — data-safe, and it reappears after the next scan); real cleanup
(trash/versions/edit) arrives with the option-B copy, which uses native NC
files. When the copy is verified and lived with, the frozen imports
(`primary/archive` + `backup/archive`) retire via `nc-archive-retire`
(import-complete + `CONFIRM=retire-archive`; ~1.15T reclaimed) — nothing
automated invokes it, and replication skips the retired pairs from then on.

Retention is space-driven end to end: NC trash and file versions never
auto-expire (`*_retention_obligation = disabled`), and snapshot history on
both pools is pruned only below a free-space floor (150 GiB primary, 100 GiB
replica), never below the newest 48 sync snapshots.

### ffmpeg and the music app

`ffmpeg` is nix-built: the flake declares `ffmpeg = pkgs.ffmpeg`, the deploy
resolves the store path and symlinks `ffmpeg` + `ffprobe` into
`/usr/local/bin` (the FHS local-bin location), and the Nextcloud units' PATH
carries `/usr/local/bin` - which is what lets the Music app auto-detect it
for transcoding and metadata of non-native formats.

The Music app installs from the NC app store (`app:install music` at deploy,
idempotent; currently 3.3.1): platform versioning and code signatures are the
store's job, and app upgrades happen via `app:upgrade`. Vendoring the app as
a hash-pinned tarball was attempted and dropped: the music project's 3.x
releases are store-only (the public GitHub releases stop at NC 32), and the
store's platform feed is an internal appdata pipeline NC fetches itself, not
a public URL the flake can pin.

## Maintenance cookbook

### Users — can this be done in Nix?

Partially, and deliberately so. The flake owns **infrastructure and
Nix-owned config values**; *instance content* (user files, users,
app-store installs) is runtime state that survives deploys — the marker
round-trip tests depend on that. Users sit in between:

- **Day-to-day (recommended): imperative occ** — user files, login sessions
  and user objects are runtime state; management commands are one-liners:

```bash
nix run .#occ -- user:add alice            # interactive password prompt
OC_PASS='Initial-Pw-123' nix run .#occ -- user:add alice --password-from-env
nix run .#occ -- user:list                 # all users
nix run .#occ -- user:info alice           # detail (quota, last login…)
OC_PASS='New-Pw-456' nix run .#occ -- user:resetpassword alice --password-from-env
nix run .#occ -- user:setting alice files quota "2 GB"
nix run .#occ -- group:add family
nix run .#occ -- group:adduser family alice
nix run .#occ -- user:disable alice
nix run .#occ -- user:enable alice
nix run .#occ -- user:delete alice         # ⚠ deletes the user's FILES too
```

- **Declarative provisioning (optional layer):** declare the users that
  *should exist* in `flake.nix`; a oneshot unit applies the desired state on
  every deploy (and `just provision` on demand):

```nix
provisionedUsers = {
  alice = { displayName = "Alice"; quota = "2 GB"; groups = [ "family" ]; };
  bob   = { };
};
```

  Semantics — deliberately narrow:
  - **creation-side only**: missing users are created with a one-shot
    random password appended to
    `/var/lib/nextcloud/provision-credentials-*.log` (0600) — hand it to the
    person and have them change it;
  - **idempotent**: quota and groups are applied to new *and* existing users;
  - **removal is explicit and self-draining**: declare the uid in
    `deprovisionedUsers = [ "alice" ];` — a per-user backup (files + full
    `pg_dump`) is taken into
    `/var/backups/nextcloud/deprovisioned/<uid>/<ts>/` and the delete is
    *refused* if that backup cannot be verified. Entries no-op once the user
    is gone. Removing a user from `provisionedUsers` alone does nothing;
  - passwords of existing users are never rotated by deploys.

### Everything else worth knowing

```bash
# background jobs (Admin Settings should show "Cron … seconds ago")
nix run .#occ -- background:cron

# maintenance mode (blocks all web access; use around risky ops)
nix run .#occ -- maintenance:mode --on
nix run .#occ -- maintenance:mode --off

# rebuild the file index when files changed out-of-band (e.g. after
# restoring an older db next to a newer data/)
nix run .#occ -- files:scan --all

# update all apps (do this BEFORE Nextcloud major upgrades)
nix run .#occ -- app:update --all
nix run .#occ -- app:list
```

Bulk import: copy files into `/var/lib/nextcloud/data/<user>/files/`,
`chown nextcloud:nextcloud`, then `files:scan --all`.

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

Two proxy-trust requirements that the app login flow (Nextcloud mobile apps)
explicitly exercises — both wired in already:

- **caddy trusts the loopback proxy**: tailscale serve connects from
  `127.0.0.1` and carries the real client's `X-Forwarded-Proto`. Caddy strips
  untrusted forwarded headers by default, so the global block pins
  `servers { trusted_proxies static 127.0.0.1/32 }` — without it NC sees
  plain HTTP and hands mobile-app login flows `http://` poll endpoints
  (unreachable — the app spins forever at "Grant access").
- **NC trusts `127.0.0.1` as a proxy** (`trusted_proxies`, set by
  `just tailscale`) so it *uses* those forwarded values.

If you ever re-run `tailscale serve` against a different local port, re-run
`just tailscale` afterwards so NC's trusted setup follows along.

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
archives.** It is protected by ZFS instead: the datadir lives on the
`primary/nextcloud` dataset and `zfs-replicate` mirrors it (and the archive) to
the backup pool hourly — whole-dataset rollback plus a second copy, but no
application-level history. See "Storage: migrating to ZFS". (The old hourly
`rsync` data mirror was retired: it duplicated the file tree onto the root SSD
and added nothing the ZFS replica and Nextcloud's never-expiring trash did not
already cover.)

- **Full** (daily 03:00, `nextcloud-backup.timer`): flips `maintenance:mode`
  on for the duration, prunes old snapshots by retention afterwards.
- **Incremental** (`nextcloud-snapshot.timer`, hourly): same contents with no
  downtime. "Incremental" = restic chunk-dedup across consecutive dumps (only
  changed DB blocks get stored); a true WAL-archiving/PITR setup is the
  follow-up if you need minute-level DB recovery.
- Retention (in flake.nix): hourly ×24, daily ×14, weekly ×6, monthly ×6.
- Repo: on the **ZFS `primary` pool**, dataset `primary/restic` mounted at
  `/var/backups/restic` (repo in `.../repo`, passphrase in `.../.restic-pass`,
  mode 0600). Keeping the repo off the root SSD is deliberate: it grows without
  bound and previously crowded `/`. Living on primary also puts it in the
  replication set, so `backup/restic` (mounted at
  `/var/backups/zfs-replica/restic`) is a send/receive replica — the repo has
  the same redundancy as the user data. The passphrase rides with the repo so a
  root-disk loss can never strand it; restic repos are always encrypted. On
  hosts without the pool (or before the migration) the jobs fall back to the
  root-disk `/var/backups/nextcloud/repo` so containers/drills and un-migrated
  machines keep working.

```bash
just backup                 # full now (brief maintenance:mode)
just snapshot               # incremental now (no downtime)
just sync-data              # snapshot + replicate data/ to the backup pool now
just backup-list            # snapshots, ids, dedup size
just backup-validate        # latest dump readable? (extract + pg_restore TOC)
just backup-validate-deep   # latest dump FULLY restores? (scratch db, dropped)
just backup-check           # repo integrity (manual, may be slow)
just backup-prune           # apply retention manually

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
then bring the repo over — either `/var/backups/nextcloud/repo` +
`.restic-pass`, or a pool copy (`/var/backups/restic` on a primary host, or the
`backup/restic` replica at `/var/backups/zfs-replica/restic`) — and run
`just restore <id>`.

Off-box later: point `RESTIC_REPOSITORY` at an ssh/S3 target in the flake —
repos are format-compatible; `just backup-list` works identically remote.

## Testing

- **Static checks (always, every commit):** `nix flake check` — Caddyfile
  validation, PHP env + extension assertions, `shellcheck -S error` over every
  generated script, PHP lint of the config writer. Unit-file verification
  (`systemd-analyze verify`) runs inside the container harness, where Ubuntu's
  systemd matches production.
- **Container harness:** `just test-docker` — boots Ubuntu 26.04 with
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
- **Backup/restore drills** (run on either harness): `backup-drill`
  (DB marker planted → snapshot → mutated → restored → assert the marker
  *rolled back*; maintenance-mode hygiene; no scratch DBs left; restic
  `check`), `restore-fresh`
  (`reset` wipes the instance → restore from the surviving repo → admin
  password, DB marker and login all return), `retention` (101 snapshots
  saturating restic's hourly buckets → `forget --prune` deletes 96, the live
  snapshot survives and still validates — documents that restic's `keep-*`
  count distinct buckets, not sliding time windows).
- **VM harness:** `just test-vm` — a real Ubuntu 26.04 VM
  (qemu/KVM + cloud-init, disposable qcow2 overlay per run on a cached cloud
  image) running the *same* scenario scripts over ssh. Adds what containers
  can't cover: cold boot, **reboot persistence** (scenario `reboot` asserts
  unit enablement, all four timers, instance state and a working login after
  a power cycle), real disk layout. KVM-accelerated when `/dev/kvm` is
  writable, TCG emulation otherwise. `NC_TEST_KEEP=1` keeps the VM;
  artifacts live in `tests/.vm-cache/` (gitignored).

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
