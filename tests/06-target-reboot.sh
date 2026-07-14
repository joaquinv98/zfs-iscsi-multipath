#!/bin/bash
# Verified I/O across a complete reboot of the single LIO/ZFS target.

VMID=${VMID:-9906}
TEST_SIZE=${TEST_SIZE:-3G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TARGET_SSH_HOST=${TARGET_SSH_HOST:-$PORTAL_A}
TARGET_SSH_KEY=${TARGET_SSH_KEY:-/etc/pve/priv/zfs/${TARGET_SSH_HOST}_id_rsa}
RUNTIME=${RUNTIME:-55}
REBOOT_AFTER=${REBOOT_AFTER:-8}
MAX_REBOOT_LAT_MS=${MAX_REBOOT_LAT_MS:-30000}
WORKDIR=${WORKDIR:-$(mktemp -d /tmp/zfsiscsimp-target-reboot.XXXXXX)}
FIO_PID=

target_ssh() {
    ssh -i "$TARGET_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
        "root@$TARGET_SSH_HOST" "$@"
}

cleanup() {
    local rc=$?
    set +e
    if [ -n "$FIO_PID" ]; then
        kill "$FIO_PID" 2>/dev/null || true
    fi
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
[ -r "$TARGET_SSH_KEY" ] || die "target SSH key '$TARGET_SSH_KEY' is missing"
target_ssh true || die "target SSH preflight failed"

while read -r vmid; do
    [ -n "$vmid" ] || continue
    qm config "$vmid" | grep -q "${STORAGE}:" &&
        die "running VM $vmid uses $STORAGE; target reboot would affect it"
done < <(qm list | awk '$3 == "running" { print $1 }')

create_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 2

log "seed 1 GiB with CRC32C headers"
fio --name=target-reboot --filename="$MP" --offset=0 --size=1G --direct=1 \
    --ioengine=libaio --rw=write --bs=64k --iodepth=32 --verify=crc32c \
    --verify_fatal=1 --do_verify=1 --group_reporting --output="$WORKDIR/seed.out"

log "run verified I/O while rebooting target $TARGET_SSH_HOST"
fio --name=target-reboot --filename="$MP" --offset=0 --size=1G --direct=1 \
    --ioengine=libaio --rw=randrw --rwmixread=30 --bs=64k --iodepth=32 \
    --runtime="$RUNTIME" --time_based --verify=crc32c --verify_fatal=1 \
    --verify_backlog=2048 --verify_async=2 --group_reporting --eta=never \
    --write_bw_log="$WORKDIR/io" --log_avg_msec=250 --output-format=json \
    --output="$WORKDIR/fio.json" &
FIO_PID=$!

sleep "$REBOOT_AFTER"
date --iso-8601=ns >"$WORKDIR/reboot-start"
target_ssh 'systemctl reboot' >/dev/null 2>&1 || true

DOWN=0
for _ in $(seq 1 30); do
    if ! target_ssh true >/dev/null 2>&1; then
        DOWN=1
        break
    fi
    sleep 1
done
[ "$DOWN" -eq 1 ] || die "target never went down"

UP=0
for _ in $(seq 1 90); do
    if target_ssh true >/dev/null 2>&1; then
        UP=1
        break
    fi
    sleep 2
done
[ "$UP" -eq 1 ] || die "target did not return within 180s"
date --iso-8601=ns >"$WORKDIR/reboot-end"

if ! wait "$FIO_PID"; then
    cat "$WORKDIR/fio.json" >&2
    die "fio failed across target reboot"
fi
FIO_PID=

WORKDIR="$WORKDIR" MAX_REBOOT_LAT_MS="$MAX_REBOOT_LAT_MS" python3 - <<'PY'
import json, os

with open(os.path.join(os.environ["WORKDIR"], "fio.json")) as fh:
    job = json.load(fh)["jobs"][0]
if job.get("error", 0):
    raise SystemExit(f"fio error={job['error']}")
directions = [job[d] for d in ("read", "write") if job[d].get("io_bytes", 0)]
max_ms = max(d.get("clat_ns", {}).get("max", 0) for d in directions) / 1_000_000
limit_ms = float(os.environ["MAX_REBOOT_LAT_MS"])
print(f"fio_err=0 max_clat_ms={max_ms:.3f} limit_ms={limit_ms:.0f}")
if max_ms > limit_ms:
    raise SystemExit(f"target reboot latency {max_ms:.3f}ms exceeds {limit_ms:.0f}ms")
PY

wait_for_paths "$WWID" 2 60
target_ssh 'zpool status -x | grep -q "all pools are healthy"'

log "full CRC verification after target recovery"
fio --name=target-reboot --filename="$MP" --offset=0 --size=1G --direct=1 \
    --ioengine=libaio --rw=read --bs=64k --iodepth=32 --verify=crc32c \
    --verify_fatal=1 --verify_only=1 --group_reporting \
    --output="$WORKDIR/post-reboot-verify.out"

echo "TARGET_REBOOT_OK workdir=$WORKDIR"
