# TODO

Deferred work — known gaps that are documented but not yet implemented.

## Schedule ZFS replication (`zfs-replicate`)

The README long described the ZFS replica as advancing hourly, but **nothing
schedules it**: `zfs-replicate` is manual-only today (`just sync-data`). The
only timers the deploy installs are `nextcloud-cron.timer`,
`nextcloud-backup.timer` (daily 03:00) and `nextcloud-snapshot.timer` (hourly —
restic db/app-state only, not the ZFS replica). Consequence: `backup/nextcloud-data`,
`backup/archive` and `backup/restic` only advance when someone runs
`just sync-data`, so an unattended host can drift arbitrarily far behind, and
`zfsKeepSnapshots = 48` is a floor of 48 *runs*, not 48 hours.

Task:

- add a `nextcloud-sync.service` (oneshot, `ExecStart=${zfsReplicate}/bin/zfs-replicate`)
  plus `nextcloud-sync.timer` (hourly, `Persistent=true`, `RandomizedDelaySec`),
  installed and enabled by deploy like the backup/snapshot timers;
- keep the same-second snapshot-collision guard (a manual run and a timer tick
  can land in the same second) and consider a `flock` so a long initial
  `zfs send` cannot overlap the next tick;
- cover it in the `zfs-drill` VM scenario (docker has no zfs), and check
  `tests/lib/reboot-assert.sh`, which currently asserts three timers;
- then restore the README wording.

Interim: the README now says replication is on demand.
