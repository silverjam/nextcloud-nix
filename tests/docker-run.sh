#!/usr/bin/env bash
# Container test harness: Ubuntu 26.04 container with real systemd as PID 1,
# multi-user Nix (cached in a docker volume), running the REAL deployment
# against the repo mounted at /test.
#
# The container's systemd is a separate instance from the host's, so unit
# names, ports, /var/lib paths and destructive flows cannot touch production.
#
# Usage: tests/docker-run.sh [install|full|reset]
# Env:   NC_TEST_KEEP=1         keep the container around for debugging
#        NC_TEST_REBUILD=1      rebuild the systemd base image
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-install}"
case "$SCENARIO" in install|full|reset|reboot|backup-drill|mirror-drill|restore-fresh|retention|users-provision|archive-import|archive-external|archive-external|upgrade-nc-major|upgrade-nc-minor|upgrade-pg-major|upgrade-pg-minor) ;;
  *) echo "usage: tests/docker-run.sh [install|full|reset|reboot|backup-drill|mirror-drill|restore-fresh|retention|upgrade-*]" >&2; exit 64 ;;
esac
command -v docker >/dev/null || { echo "docker not available" >&2; exit 1; }

BASE_IMG="nc-test-base:26.04"
C="nc-test-$(date +%s)"
cleanup() {
  if [ "${NC_TEST_KEEP:-0}" = "1" ]; then
    echo
    echo "[harness] container kept for debugging: docker exec -it $C bash"
    echo "[harness] tear down later with: docker rm -f $C"
    return
  fi
  docker rm -f "$C" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ubuntu docker images ship without systemd: bootstrap once, commit as an
# image with /sbin/init (cached; NC_TEST_REBUILD=1 to refresh)
if ! docker image inspect "$BASE_IMG" >/dev/null 2>&1 \
   || [ "${NC_TEST_REBUILD:-0}" = "1" ]; then
  echo "[harness] building systemd base image ($BASE_IMG)"
  docker rm -f nc-test-bootstrap >/dev/null 2>&1 || true
  docker run -d --name nc-test-bootstrap ubuntu:26.04 sleep infinity >/dev/null
  docker exec nc-test-bootstrap bash -c \
    'export DEBIAN_FRONTEND=noninteractive
     apt-get update -qq
     apt-get install -y -qq systemd systemd-sysv dbus sudo curl ca-certificates xz-utils git findutils >/dev/null'
  docker commit --change 'ENTRYPOINT ["/sbin/init"]' nc-test-bootstrap "$BASE_IMG" >/dev/null
  docker rm -f nc-test-bootstrap >/dev/null
fi

echo "[harness] booting container $C (systemd container)"
docker run -d --privileged --name "$C" \
  --hostname nextcloud-test \
  -v nc-test-nix:/nix \
  "$BASE_IMG" /sbin/init >/dev/null

# NOTE: the repo is docker-cp'd into the container (not bind-mounted): nix's
# libgit2 refuses git repos owned by another uid, and cp preserves host uids —
# so the copy is chowned to root afterwards.
docker exec "$C" mkdir -p /test
docker cp "$REPO/." "$C:/test/" >/dev/null
docker exec "$C" chown -R root:root /test

echo "[harness] waiting for container systemd"
systemd_up=""
for _ in $(seq 1 60); do
  state="$(docker exec "$C" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) systemd_up=1; break ;; esac
  sleep 1
done
[ -n "$systemd_up" ] || {
  docker logs --tail 30 "$C" 2>&1 | sed 's/^/  | /' >&2
  exit 1
}
echo "[harness] systemd is $state"

echo "[harness] installing Nix"
docker exec -i "$C" bash -s < "$REPO/tests/lib/install-nix.sh"

echo "[harness] running scenario: $SCENARIO"
set +e
docker exec -i "$C" bash -s < <(
  cat "$REPO/tests/lib/prelude.sh" "$REPO/tests/lib/web.sh" \
      "$REPO/tests/lib/upgrade.sh" "$REPO/tests/scenarios/$SCENARIO.sh"
)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "[harness] scenario failed (rc=$rc) — journal dump (init/provision/db):"
  docker exec "$C" bash -c \
    'journalctl -u nextcloud-init -u nextcloud-provision -u nextcloud-db -q --no-pager -o cat | tail -n 25' \
    2>/dev/null | sed 's/^/  | /' || true
  exit "$rc"
fi

echo
echo "[harness] ✔ scenario '$SCENARIO' passed"
