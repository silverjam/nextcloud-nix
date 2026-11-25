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
8. **CI runs serialize on a concurrency group; a waiting run shows
   `jobs=0`.** That is normal, NOT a "ghost run" (an earlier version of this
   note misread it). The workflow pins
   `concurrency: group: ${{ github.workflow }}-${{ github.ref }}` with
   `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`, so a
   push/dispatch never cancels a run that is already going: the new run sits
   `pending` and GitHub creates its jobs only once the group frees, so
   `gh run view <id>` legitimately shows `status=pending jobs=0` for many
   minutes. What DOES happen: queueing a new run cancels any *previously
   pending* run in the group, so the newest push's run can end up
   `cancelled` with `jobs=0` while an older run finishes — a push's CI may
   therefore never execute at all. Pushes and `workflow_dispatch` runs share
   the group, so a dispatch queues behind an in-progress push run too.
   Workaround: check that the run's `headSha` is the commit you care about;
   wait for the group to drain, or trigger an explicit
   `gh workflow run CI --ref main -f run_docker=true -f docker_scenario=all`;
   `gh run watch` in the background for long matrices.

## Nix indented-string (`''...''`) traps in flake recipes

1. **A backslash is literal inside `''` strings** (unlike double-quoted nix
   strings), and `'''` escapes to a single `'`. Consequence: a bash EOL line
   continuation must be typed as ONE backslash at source; `\\` ships as two
   backslashes, which bash reads as an escaped-backslash and the
   continuation silently breaks (`find: paths must precede expression: '\'`).
   This broke a `find \ -o ...` and an `ffmpeg ... \ -c:v` in the committed
   transcode recipe.
2. **A bare uppercase variable word is a command name, not a typo check**:
   `FFPROBE -v quiet ...` runs a command named FFPROBE; with
   `2>/dev/null | ... || true` the failure is masked and every file is
   "skipped as playable". Found only by `bash -x` on the BUILT recipe (the
   xtrace shows the substituted command line; the `$f` expansion looked
   correct, the missing `$FFPROBE` did not).
3. **`nix build --print-out-paths` output order varies per package**
   (ffmpeg: bin first; postgresql: man first) - never pick an output with
   head/tail-1. Select the output that has the binary:
   `while read -r p; do [ -x "$p/bin/$tool" ] && ...`.
4. **Validate recipe logic by running it, not reading it**: `bash -n` +
   grep both passed on a recipe whose find-continuation was broken and
   whose ffprobe call was a bare word. `bash -x <built-recipe>` and one
   manual invocation against a planted fixture caught both.
5. **Beware `| head -N` truncation while validating**: closing the pipe
   SIGPIPEs the producer mid-run (a docker exec validation script died
   silently partway through an ffmpeg convert). Filter with grep without
   head, or write full output to a file when the producer must finish.

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
9. **A bind mount survives `zfs umount <dataset>` but is detached by
   `zfs destroy`** (zfs 2.4.1): the bind target stays busy for `umount`
   while a reader holds it, yet destroying the dataset tears the bind down
   and leaves an empty directory. Remove the bind target with `rmdir`
   *after* the destroy - `nc-archive-retire` did it before, saw a mounted
   path, and left "Archive (Read only)" behind (caught by zfs-drill).
   Open readers still make the umount and the destroy fail EBUSY.

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
5. **DAV PROPFIND hrefs are URL-encoded** - the XML body contains
   `Archive%202007-2026`, never the raw spaced name. assert greps must use
   the encoded form (or a prefix); a raw-name grep fails instantly and
   looks like a share/mount problem.
6. **A recipient delete of a shared file makes TWO `oc_files_trash` rows**
   (the owner's real entry + the recipient's restore-the-share entry), both
   `deleted_by`-recipient, same timestamp. Asserting count=1 fails; assert
   `deleted_by='user' AND id=<name>` count=2.
7. **App store distribution**: some apps (music 3.x) publish tarballs ONLY
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
   typed `CONFIRM=...` gate that is **dry-run by default**: without the
   CONFIRM the recipe prints the exact commands it would run — extracted from
   the recipe's own `# >>> APPLY` / `# <<< APPLY` block via
   `awk ... "$0"` (never a restated paraphrase, so the plan cannot drift) — on
   stdout, plus one
   `DRY RUN — nothing was changed. Set CONFIRM=<word> to proceed.` line on
   stderr, and exits 0 having touched nothing. The stderr line is deliberate —
   the scenarios capture stderr (`2>&1 >/dev/null`) and grep it for
   `CONFIRM`; the command list goes to stdout so it stays pipeable. Note the
   `awk` markers must be anchored (`^[[:space:]]*# >>> APPLY[[:space:]]*$`) —
   an unanchored pattern also matches the helper's own `awk` line, which sits
   *before* the start marker, and the extraction then prints everything from
   there. Nothing destructive is automated, and recipes umount before
   `zfs destroy`.
4. **Nix-owned Nextcloud config is an overlay, never a rewrite**: write
   `config/nix.config.php` (Nextcloud merges every `*.config.php` over
   `config.php` at read time) and leave `config.php` to Nextcloud
   (dbpassword, instanceid, secret, trusted domains). Never
   `file_put_contents` the main config. The deploy must also never print the
   admin password (0600 `/var/lib/nextcloud/admin-password`).
