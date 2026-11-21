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
          exec sudo "$0" "$@"
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
        # F layer: unit-file verification moved to the Docker harness (tests/)
        # — sandboxed systemd-analyze insists on /run/systemd, and running it
        # inside the container against Ubuntu's systemd is more faithful.
        # F layer: shellcheck every generated bash script
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
                ${initScript}
              touch $out
            '';
        # F layer: the generated PHP config-writer must parse
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
