#!/bin/bash
# Verified-I/O failover test for each path and a short complete fabric outage.

TEST_SIZE=${TEST_SIZE:-4G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

RUNTIME=${RUNTIME:-70}
CUT_AFTER=${CUT_AFTER:-12}
CUT_DURATION=${CUT_DURATION:-25}
TEST_ALL_PATHS=${TEST_ALL_PATHS:-1}
WORKDIR=${WORKDIR:-$(mktemp -d /tmp/zfsiscsimp-reliability.XXXXXX)}
MAX_SINGLE_PATH_LAT_MS=${MAX_SINGLE_PATH_LAT_MS:-15000}
MAX_ALL_PATH_LAT_MS=${MAX_ALL_PATH_LAT_MS:-16000}
CASES=${CASES:-path-a path-b both-paths}
FIO_PID=
MONITOR_PID=

cleanup() {
    local rc=$?
    set +e
    if [ -n "$FIO_PID" ]; then
        kill "$FIO_PID" 2>/dev/null || true
    fi
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || true
    fi
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
create_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 2

log "seed 2 GiB with CRC32C verification headers"
fio --name=reliability --filename="$MP" --offset=0 --size=2G --direct=1 \
    --ioengine=libaio --rw=write --bs=64k --iodepth=32 --verify=crc32c \
    --verify_fatal=1 --do_verify=1 --group_reporting --output="$WORKDIR/seed.out"

run_cut() {
    local label=$1 portals=$2 duration=$3
    local case_dir="$WORKDIR/$label"
    mkdir -p "$case_dir"
    remove_drop_rules
    wait_for_paths "$WWID" 2 45

    log "$label: verified mixed IO; cut $portals for ${duration}s"
    fio --name=reliability --filename="$MP" --offset=0 --size=2G --direct=1 \
        --ioengine=libaio --rw=randrw --rwmixread=30 --bs=64k --iodepth=32 \
        --runtime="$RUNTIME" --time_based --verify=crc32c --verify_fatal=1 \
        --verify_backlog=2048 --verify_async=2 --group_reporting --eta=never \
        --write_bw_log="$case_dir/io" --log_avg_msec=250 --output-format=json \
        --output="$case_dir/fio.json" &
    FIO_PID=$!

    (
        while kill -0 "$FIO_PID" 2>/dev/null; do
            printf 't=%s ' "$SECONDS"
            multipathd show paths raw format '%w|%d|%t|%o|%T' | awk -F'|' -v w="$WWID" '$1 == w { printf "%s=%s/%s/%s ", $2, $3, $4, $5 }'
            echo
            sleep 1
        done
    ) >"$case_dir/paths.log" &
    MONITOR_PID=$!

    sleep "$CUT_AFTER"
    for portal in $portals; do drop_portal "$portal"; done
    date --iso-8601=ns >"$case_dir/cut-start"
    sleep "$duration"
    remove_drop_rules
    date --iso-8601=ns >"$case_dir/cut-end"

    if ! wait "$FIO_PID"; then
        cat "$case_dir/fio.json" >&2
        die "$label fio failed"
    fi
    FIO_PID=
    wait "$MONITOR_PID" || true
    MONITOR_PID=
    if [ "$label" != both-paths ]; then
        awk '
            /active\/running\/ready/ { next }
            { print "no usable path in sample: " $0 > "/dev/stderr"; bad=1 }
            END { exit bad }
        ' "$case_dir/paths.log" || die "$label lost the nominally healthy path"
    fi
    MAX_LAT_MS=$MAX_SINGLE_PATH_LAT_MS
    [ "$label" = both-paths ] && MAX_LAT_MS=$MAX_ALL_PATH_LAT_MS
    CASE_DIR="$case_dir" MAX_LAT_MS="$MAX_LAT_MS" python3 - <<'PY'
import json, os, sys

with open(os.path.join(os.environ["CASE_DIR"], "fio.json")) as fh:
    data = json.load(fh)
job = data["jobs"][0]
if job.get("error", 0):
    raise SystemExit(f"fio error={job['error']}")
directions = [job[d] for d in ("read", "write") if job[d].get("io_bytes", 0)]
max_ms = max(d.get("clat_ns", {}).get("max", 0) for d in directions) / 1_000_000
limit_ms = float(os.environ["MAX_LAT_MS"])
print(f"fio_err=0 max_clat_ms={max_ms:.3f} limit_ms={limit_ms:.0f}")
if max_ms > limit_ms:
    raise SystemExit(f"failover latency {max_ms:.3f}ms exceeds {limit_ms:.0f}ms")
PY
    wait_for_paths "$WWID" 2 60

    # Verify every block in the test range after recovery, independently of
    # fio's rolling verify backlog during the outage.
    fio --name=reliability --filename="$MP" --offset=0 --size=2G --direct=1 \
        --ioengine=libaio --rw=read --bs=64k --iodepth=32 --verify=crc32c \
        --verify_fatal=1 --verify_only=1 --group_reporting \
        --output="$case_dir/post-recovery-verify.out"
    grep -E 'err= 0|lat \(|clat \(' "$case_dir/post-recovery-verify.out" | head -8
}

if [[ " $CASES " == *" path-a "* ]]; then
    run_cut path-a "$PORTAL_A" "$CUT_DURATION"
fi
if [[ " $CASES " == *" path-b "* ]]; then
    run_cut path-b "$PORTAL_B" "$CUT_DURATION"
fi
if [ "$TEST_ALL_PATHS" -eq 1 ] && [[ " $CASES " == *" both-paths "* ]]; then
    # Shorter than the finite no_path_retry window: IO must queue and recover.
    run_cut both-paths "$PORTAL_A $PORTAL_B" 8
fi

echo "RELIABILITY_OK workdir=$WORKDIR"
