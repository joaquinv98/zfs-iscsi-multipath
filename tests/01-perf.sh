#!/bin/bash
# Reproducible two-path vs one-path benchmark using the same dm-multipath map.

TEST_SIZE=${TEST_SIZE:-6G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

RUNTIME=${RUNTIME:-20}
REPEATS=${REPEATS:-2}
IODEPTH=${IODEPTH:-8}
PORTAL_SINGLE=${PORTAL_SINGLE:-$PORTAL_B}
WORKDIR=${WORKDIR:-$(mktemp -d /tmp/zfsiscsimp-perf.XXXXXX)}
SINGLE_PATH_BLOCKED=0
RATE_LIMIT_MBIT=${RATE_LIMIT_MBIT:-0}
RATE_IFACES=${RATE_IFACES:-ens20 ens21}
TEST_MODES=${TEST_MODES:-multipath single}
TARGET_SSH_HOST=${TARGET_SSH_HOST:-$PORTAL_A}
TARGET_SSH_KEY=${TARGET_SSH_KEY:-/etc/pve/priv/zfs/${TARGET_SSH_HOST}_id_rsa}
RATE_LIMIT_ACTIVE=0

target_ssh() {
    ssh -n -i "$TARGET_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
        "root@$TARGET_SSH_HOST" "$@"
}

restore_rate_limits() {
    local iface local_qdisc remote_qdisc failed=0
    for iface in $RATE_IFACES; do
        tc qdisc replace dev "$iface" root fq_codel || failed=1
        target_ssh tc qdisc replace dev "$iface" root fq_codel || failed=1
        local_qdisc=$(tc qdisc show dev "$iface")
        remote_qdisc=$(target_ssh tc qdisc show dev "$iface")
        [[ "$local_qdisc" == qdisc\ fq_codel*root* ]] || failed=1
        [[ "$remote_qdisc" == qdisc\ fq_codel*root* ]] || failed=1
    done
    if [ "$failed" -eq 0 ]; then
        RATE_LIMIT_ACTIVE=0
        return 0
    fi
    return 1
}

capture_rate_stats() {
    local iface
    {
        date --iso-8601=ns
        for iface in $RATE_IFACES; do
            echo "=== $iface ==="
            tc -s qdisc show dev "$iface"
        done
    } >"$WORKDIR/rate-limit-initiator-final.txt"
    {
        date --iso-8601=ns
        for iface in $RATE_IFACES; do
            echo "=== $iface ==="
            target_ssh tc -s qdisc show dev "$iface"
        done
    } >"$WORKDIR/rate-limit-target-final.txt"
}

apply_rate_limits() {
    local iface local_qdisc remote_qdisc
    [ "$RATE_LIMIT_MBIT" != 0 ] || return 0
    [[ "$RATE_LIMIT_MBIT" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "RATE_LIMIT_MBIT must be a positive number or 0"
    [ -r "$TARGET_SSH_KEY" ] || die "target SSH key '$TARGET_SSH_KEY' is missing"
    command -v tc >/dev/null || die "local tc not found"
    target_ssh command -v tc >/dev/null || die "target tc not found"

    # Refuse to overwrite an administrator-supplied qdisc. The test restores
    # the known fq_codel baseline on every exit path.
    for iface in $RATE_IFACES; do
        [[ "$iface" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "invalid interface '$iface'"
        local_qdisc=$(tc qdisc show dev "$iface")
        remote_qdisc=$(target_ssh tc qdisc show dev "$iface")
        [[ "$local_qdisc" == qdisc\ fq_codel*root* ]] ||
            die "local $iface does not have the expected fq_codel root qdisc"
        [[ "$remote_qdisc" == qdisc\ fq_codel*root* ]] ||
            die "target $iface does not have the expected fq_codel root qdisc"
    done

    RATE_LIMIT_ACTIVE=1
    for iface in $RATE_IFACES; do
        tc qdisc replace dev "$iface" root tbf rate "${RATE_LIMIT_MBIT}mbit" \
            burst 256k latency 100ms
        target_ssh tc qdisc replace dev "$iface" root tbf \
            rate "${RATE_LIMIT_MBIT}mbit" burst 256k latency 100ms
    done

    {
        echo "rate=${RATE_LIMIT_MBIT}mbit per path; egress shaped on initiator and target"
        for iface in $RATE_IFACES; do
            tc qdisc show dev "$iface"
        done
    } >"$WORKDIR/rate-limit-initiator.txt"
    {
        echo "rate=${RATE_LIMIT_MBIT}mbit per path; target=$TARGET_SSH_HOST"
        for iface in $RATE_IFACES; do
            target_ssh tc qdisc show dev "$iface"
        done
    } >"$WORKDIR/rate-limit-target.txt"
}

cleanup() {
    local rc=$?
    set +e
    if [ "$RATE_LIMIT_ACTIVE" -eq 1 ]; then
        capture_rate_stats || true
        restore_rate_limits || true
    fi
    if [ "$SINGLE_PATH_BLOCKED" -eq 1 ]; then
        remove_drop_rules
    fi
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
[[ " $TEST_MODES " == *" multipath "* || " $TEST_MODES " == *" single "* ]] ||
    die "TEST_MODES must contain 'multipath', 'single', or both"

while read -r vmid; do
    [ -n "$vmid" ] || continue
    if qm config "$vmid" | grep -q "${STORAGE}:"; then
        die "running VM $vmid uses $STORAGE; performance test blocks one shared iSCSI path"
    fi
done < <(qm list | awk '$3 == "running" { print $1 }')

log "allocate $TEST_SIZE scratch LUN and precondition its full address range"
create_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 2

fio --name=precondition --filename="$MP" --direct=1 --ioengine=libaio --rw=write \
    --bs=1M --iodepth=32 --size="$TEST_SIZE" --numjobs=1 --group_reporting \
    --output="$WORKDIR/precondition.txt"

if [ "$RATE_LIMIT_MBIT" != 0 ]; then
    log "shape each storage path to ${RATE_LIMIT_MBIT} Mbit/s in both directions"
    apply_rate_limits
fi

run_case() {
    local mode=$1 rw=$2 bs=$3 repeat=$4
    local out="$WORKDIR/${mode}-${rw}-${repeat}.json"
    echo "mode=$mode workload=$rw bs=$bs repeat=$repeat"
    fio --name="${mode}-${rw}" --filename="$MP" --direct=1 --invalidate=1 \
        --ioengine=libaio --rw="$rw" --bs="$bs" --iodepth="$IODEPTH" --numjobs=4 \
        --size=25% --offset_increment=25% --runtime="$RUNTIME" --time_based \
        --group_reporting --randrepeat=1 --norandommap --output-format=json --output="$out"
}

wait_for_exact_paths() {
    local expected=$1 timeout=${2:-30} start=$SECONDS count
    while (( SECONDS - start < timeout )); do
        count=$(usable_paths "$WWID")
        [ "$count" -eq "$expected" ] && return 0
        sleep 1
    done
    multipath -ll "$WWID" >&2 || true
    die "map did not settle on exactly $expected usable path(s) within ${timeout}s"
}

if [[ " $TEST_MODES " == *" multipath "* ]]; then
    log "two usable paths"
    for repeat in $(seq 1 "$REPEATS"); do
        run_case multipath read 1M "$repeat"
        run_case multipath randread 4k "$repeat"
        run_case multipath write 1M "$repeat"
        run_case multipath randwrite 4k "$repeat"
    done
fi

if [[ " $TEST_MODES " == *" single "* ]]; then
    log "one usable path through the same dm map"
    drop_portal "$PORTAL_SINGLE"
    SINGLE_PATH_BLOCKED=1
    wait_for_exact_paths 1 30
    for repeat in $(seq 1 "$REPEATS"); do
        run_case single read 1M "$repeat"
        run_case single randread 4k "$repeat"
        run_case single write 1M "$repeat"
        run_case single randwrite 4k "$repeat"
    done

    remove_drop_rules
    SINGLE_PATH_BLOCKED=0
    wait_for_paths "$WWID" 2 45
fi

log "aggregated results (mean across repeats)"
WORKDIR="$WORKDIR" python3 - <<'PY'
import glob, json, os, statistics

rows = {}
for path in glob.glob(os.path.join(os.environ["WORKDIR"], "*.json")):
    name = os.path.basename(path).removesuffix(".json")
    mode, workload, _repeat = name.rsplit("-", 2)
    with open(path) as fh:
        data = json.load(fh)
    jobs = data["jobs"]
    direction = "read" if "read" in workload else "write"
    stats = jobs[0][direction]
    bw = stats.get("bw_bytes", 0) / 1_000_000
    iops = stats.get("iops", 0)
    clat = stats.get("clat_ns", {})
    pct = clat.get("percentile", {})
    p99 = float(pct.get("99.000000", 0)) / 1_000_000
    rows.setdefault((mode, workload), []).append((bw, iops, p99))

print(f"{'mode':<10} {'workload':<10} {'MB/s':>12} {'IOPS':>12} {'p99 ms':>12}")
for key in sorted(rows):
    values = rows[key]
    means = [statistics.mean(x[i] for x in values) for i in range(3)]
    print(f"{key[0]:<10} {key[1]:<10} {means[0]:12.1f} {means[1]:12.0f} {means[2]:12.3f}")

if {key[0] for key in rows} == {"multipath", "single"}:
    print("\nmultipath/single bandwidth ratio")
    for workload in sorted({key[1] for key in rows}):
        multi = statistics.mean(x[0] for x in rows[("multipath", workload)])
        single = statistics.mean(x[0] for x in rows[("single", workload)])
        print(f"{workload:<10} {multi / single:8.3f}x")
PY

if [ "$RATE_LIMIT_ACTIVE" -eq 1 ]; then
    capture_rate_stats
    restore_rate_limits || die "failed to restore fq_codel on every shaped interface"
fi

echo "PERF_OK workdir=$WORKDIR"
