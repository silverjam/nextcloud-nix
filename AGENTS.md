# AGENTS.md - agent working notes for this repo

Rules and hard-won session lessons for AI agents (and humans) working in this
repo. Read before editing `flake.nix` or the test harness. Everything here was
verified against real failures during the ZFS migration (Nov 2026).

## Tooling rules (harness)

1. **Never type doubled single-quotes (`''`) in shell command text.** The
   harness strips `''` sequences from command strings before the shell runs
   them, which mangles:
   - nix indented-string contents (`''${VAR}` escapes, `'';` terminators) in
     scripts you generate or edit,
   - python heredocs whose code contains `'''`/`''` literals.
   Effects observed: recipes whose `sudo CONFIRM="${CONFIRM:-}"` silently
   became `sudo CONFIRM="CONFIRM:-"`; a nix `'';` terminator vanishing and
   leaving a parse error; python edits that were no-ops.
   **Reliable carriers**: the `write` tool and the `edit` tool (both move
   content verbatim). For anything else, build the two apostrophes with
   `chr(39)` in python or read content from a file written by the write tool.
2. **Never modify `flake.nix` via python-heredoc writes.** Several such
   writes silently reverted between commands (mtime changed, content reset.)
   Use the `edit` tool for flake changes, then immediately
   `grep`-verify + `nix flake check` + build before committing.
3. **Commit after each verified change.** Do not leave multi-file, mutually
   dependent states uncommitted across tool calls; partial commits have
   captured reverted content before (a commit message describing work that
   `git show` disproved).
4. **Validate the built artifact, not the source.** After recipe edits:
   `nix build .#<recipe> --no-link`, then `bash -n` and grep the built
   `/nix/store/.../bin/<recipe>` file. `nix eval --raw` returns an outPath
   without building the file into existence.
5. The deploy is exposed via the flake `apps` collection (`nix run .#deploy`),
   not under `packages` - `.#packages...deploy` does not resolve.
6. **docker cp / exec /tmp writes**: verify with `ls` in the SAME command
   before reading in a later command; container /tmp writes have gone missing
   between execs. Prefer `docker exec -i <c> bash < script.sh` (stdin from a
   write-tool-created file) over `docker cp` for remote scripts.
7. **heredoc bodies are command text**: the `''`-stripping applies to the
   whole command string including heredoc bodies of the tool call.

## Bash / shell traps in the recipes and tests

1. **Command substitutions fail silently under `set -e` on empty input.**
   `X="$(curl ... | grep ... | grep ...)"` - a middle grep with no match
   exits 1 and (with pipefail) kills the script with no message. Guard with
   `|| true` inside the substitution.
2. **`grep -q` mid-pipe under pipefail SIGPIPEs the producer** (exit 141);
   `grep -c` exits 1 on zero matches. Prefer `grep -c 'x'` guards only with
   `|| true`, count via `awk '/x/{n++} END{print n+0}'`, and use
   `find <dir> -type f -print -quit` instead of `find | grep -q`.
3. **`lsblk <node>` prints the node AND its descendants.** Use
   `lsblk -d -no ...` (nodeps) for single-device queries.
4. **Partition nodes carry no MODEL.** Read drive identity via
   `lsblk -no PKNAME <partition>` then `lsblk -d -no MODEL <parent-disk>`.
5. **Unmount before `zfs destroy`** - destroying a mounted dataset fails
   silently under `|| true` and leaves the dataset alive.
6. **Same-second snapshot collisions**: replicate-style runners create
   `@sync-<timestamp>` snapshots; guard loop checks must cover ALL datasets
   that get stamped, not just one (an earlier run's archive snapshot of the
   same second will otherwise collide).
7. **sudo env_reset**: recipe self-promotion (`exec sudo ...`) strips env:
   PASS the needed variables explicitly on the sudo line (CONFIRM, FORCE)
   and export `PATH` + `NIX_CONFIG` ("experimental-features = nix-command
   flakes") at recipe tops before any nix/flake calls.
8. **occ must run as the nextcloud user with the instance env**:
   `sudo -u nextcloud env HOME=... NEXTCLOUD_CONFIG_DIR=... php <nc>/occ`.
   Raw `php occ` from a bare shell reports "Nextcloud is not installed".

## Nextcloud 34 behavior notes

1. **type-3 (group) OCS shares silently drop their recipient**: the share is
   created 200-ok with empty `share_with` and default 31 permissions, for
   every POST body variant (form, urlencoded, JSON) and both OCS v1/v2.
   Workaround (used by nc-archive-share / nc-import-archive): create
   **per-member user-shares** (type 0), resolved via
   `occ group:list --output=json`.
2. **`occ files:scan --path=<user>/files/<dir>` walks mountpoint-bound dirs**;
   the full-user `occ files:scan` stops at mountpoint directories (the bind
   mounted into a user tree yields only the directory row).
3. **After creating shares, scan once more** - the recipient-side DAV
   resolves write ops (delete etc.) only after the shared nodes' filecache
   permissions refresh; otherwise write/delete ops 404 with an empty
   `Forbidden` exception.
4. **Deleting shares/files that reference a vanished dataset** is done by
   NC's background maintenance automatically; a share can vanish from the DB
   minutes after creation - re-check state instead of assuming a UI bug.
5. **App store distribution**: some apps (music 3.x) publish tarballs ONLY
   through the appstore pipeline (no public URL to pin); per-app choice:
   vendored hash-pinned fetchurl when the author publishes public tarballs
   (files_archive pattern), store-driven `app:install`+`app:enable`
   (idempotent) otherwise. Platform compat lives in appinfo/info.xml.

## Nix-native patterns (do not regress)

1. **Runtime tools for NC units ride a `pkgs.buildEnv`** (`ncToolsEnv`) whose
   store path is interpolated into every unit's `Environment="PATH=..."`
   line at eval time. Do NOT symlink nix binaries into /usr/local/bin or
   /etc/<x>-bin (both patterns were tried and reverted in the same session).
2. **Unit env strips are not a delivery mechanism**: anything needed by a
   recipe at runtime comes from store-path interpolation at eval, or from
   the env-wrapped occ.
3. **Retire/destroy flows** carry a stamped precondition chain
   (`migration-complete` -> `import-complete` -> `archive-retired`) and a
   typed `CONFIRM=...` gate; nothing destructive is automated, and
   recipes umount before `zfs destroy`.
