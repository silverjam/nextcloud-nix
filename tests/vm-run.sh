#!/usr/bin/env bash
# Layer-C test harness: a REAL Ubuntu VM — qemu/KVM + cloud-init.
#
# Reuses the docker harness assets (tests/lib/*, tests/scenarios/*): the
# scripts are environment-agnostic and are streamed over ssh instead of
# docker exec. Adds what containers can't cover: cold boot, reboot
# persistence, real disk layout, timers surviving power cycles.
#
# Disposable by construction: each run boots an overlay qcow2 on top of a
# cached cloud image. NC_TEST_KEEP=1 keeps the VM + overlay for debugging.
#
# Usage: tests/vm-run.sh [install|full|reset|reboot]
# First run downloads the ~1GB cloud image (cached in tests/.vm-cache).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$REPO/tests/.vm-cache"
SCENARIO="${1:-install}"
case "$SCENARIO" in install|full|reset|reboot) ;;
  *) echo "usage: tests/vm-run.sh [install|full|reset|reboot]" >&2; exit 64 ;;
esac
command -v ssh >/dev/null || { echo "ssh not available" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar not available" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
DISK="$CACHE/overlay-$TS.qcow2"
SEED="$CACHE/seed-$TS.iso"
CONSOLE="$CACHE/console-$TS.log"
PIDFILE="$CACHE/qemu-$TS.pid"
IMGCACHE="$CACHE/resolute-server-cloudimg-amd64.img"
KEY="$CACHE/ssh_key"
SSH_PORT=""

mkdir -p "$CACHE"

# --- host tools from nix (qemu for boot + images, genisoimage for the seed)
QEMU_OUT="$(nix build nixpkgs#qemu_kvm --no-link --print-out-paths | tail -1)"
ISO_OUT="$(nix build nixpkgs#xorriso --no-link --print-out-paths | tail -1)"
QIMG="$QEMU_OUT/bin/qemu-img"
QEMU="$QEMU_OUT/bin/qemu-system-x86_64"

cleanup() {
  if [ "${NC_TEST_KEEP:-0}" = "1" ] && [ -f "$PIDFILE" ]; then
    echo
    echo "[harness] VM kept for debugging (overlay: $(basename "$DISK"))"
    echo "[harness] ssh:   ssh -p $SSH_PORT -i $KEY root@127.0.0.1"
    echo "[harness] stop:  kill \$(cat $PIDFILE) && rm $DISK"
    return
  fi
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$DISK" "$SEED" "$PIDFILE"
  rm -rf "$CACHE/isoin-$TS"
}
trap cleanup EXIT

# --- ephemeral ssh port
for p in $(seq 2222 2231); do
  if ! ss -ltn 2>/dev/null | grep -q ":$p "; then SSH_PORT="$p"; break; fi
done
[ -n "$SSH_PORT" ] || { echo "no free ssh port 2222-2231" >&2; exit 1; }
SSH_OPTS=(-p "$SSH_PORT"
  -i "$KEY" -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5 -o LogLevel=ERROR)
SSHRUN() { ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }

# --- ssh key (stable across runs: the seed embeds the pubkey)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"

# --- base cloud image (download once)
if [ ! -s "$IMGCACHE" ]; then
  echo "[harness] downloading Ubuntu 26.04 cloud image (~1GB, once)"
  curl -fL --retry 3 -o "$IMGCACHE.tmp" \
    "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
  mv "$IMGCACHE.tmp" "$IMGCACHE"
fi

# --- bootstrap image with systemd present (vm cloud images have it built-in;
#     no systemd-sysv needed — /sbin/init exists on cloud images)
echo "[harness] building seed iso"
# NoCloud requires the EXACT basenames user-data + meta-data
ISOIN="$CACHE/isoin-$TS"
mkdir -p "$ISOIN"
cat > "$ISOIN/user-data" <<EOF
#cloud-config
disable_root: false
hostname: nextcloud-test-vm
ssh_authorized_keys:
  - $(cut -d' ' -f1,2 "$KEY.pub")
EOF
cat > "$ISOIN/meta-data" <<EOF
instance-id: nc-test-vm
local-hostname: nextcloud-test-vm
EOF
"$ISO_OUT/bin/xorriso" -as mkisofs -output "$SEED" -volid cidata -joliet -rock \
  "$ISOIN/user-data" "$ISOIN/meta-data"

echo "[harness] creating boot overlay"
"$QIMG" create -f qcow2 -b "$IMGCACHE" -F qcow2 "$DISK"
# base cloud images have a 3.5G virtual disk — too small for apt+nix;
# grow to 12G and let cloud-init's growpart expand the rootfs on first boot
"$QIMG" resize "$DISK" 12G

# --- boot (KVM when available, TCG emulation otherwise)
ACCEL="accel=tcg"
CPUARG=""
if [ -w /dev/kvm ]; then ACCEL="accel=kvm"; CPUARG="-cpu host"; fi
PORTFWD="127.0.0.1:$SSH_PORT-:22"
echo "[harness] booting vm (scenario: $SCENARIO, port $SSH_PORT, $ACCEL)"
"$QEMU" \
  -machine "q35,$ACCEL" $CPUARG -m 2048 -smp 2 \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -cdrom "$SEED" \
  -device virtio-net-pci,netdev=n0 \
  -netdev "user,id=n0,hostfwd=tcp:$PORTFWD" \
  -device virtio-rng-pci \
  -display none -daemonize \
  -pidfile "$PIDFILE" \
  -serial "file:$CONSOLE" >/dev/null

up=""
for _ in $(seq 1 240); do
  SSHRUN true 2>/dev/null && { up=1; break; }
  sleep 2
done
[ -n "$up" ] || {
  echo "[harness] ssh never came up — cloud-init datasource evidence:" >&2
  grep -aA4 -iE 'datasource|nocloud|cidata|ds-identify' "$CONSOLE" | tail -24 >&2 || true
  echo "[harness] console tail:" >&2
  tail -15 "$CONSOLE" >&2
  exit 1
}
echo "[harness] vm is up (ssh -p $SSH_PORT root@127.0.0.1)"

echo "[harness] copying repo into vm (/test)"
tar -C "$REPO" --exclude='./.git' -cf - . | SSHRUN 'mkdir -p /test && tar -C /test -xf -'

echo "[harness] installing Nix in vm"
if [ "$SCENARIO" = "reboot" ]; then
  # install once, then stream the install asserts + reboot + post-reboot asserts
  STREAM1="$REPO/tests/lib/prelude.sh $REPO/tests/lib/web.sh $REPO/tests/scenarios/install.sh"
  STREAM2="$REPO/tests/lib/prelude.sh $REPO/tests/lib/web.sh $REPO/tests/lib/reboot-assert.sh"
  cat $STREAM1 | SSHRUN 'bash -s'
  SSHRUN 'sync && systemctl reboot' 2>/dev/null || true
  echo "[harness] vm rebooting"
  for _ in $(seq 1 180); do
    SSHRUN true 2>/dev/null && break
    sleep 2
  done
  SSHRUN 'systemctl is-system-running --wait 2>/dev/null || systemctl is-system-running' >/dev/null
  echo "[harness] vm back up — asserting persistence"
  cat $STREAM2 | SSHRUN 'bash -s'
else
  cat "$REPO/tests/lib/prelude.sh" "$REPO/tests/lib/web.sh" \
      "$REPO/tests/scenarios/$SCENARIO.sh" | SSHRUN 'bash -s'
fi

echo
echo "[harness] ✔ scenario '$SCENARIO' passed"
