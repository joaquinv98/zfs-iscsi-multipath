#!/bin/bash
# Compare the same dm-multipath device with one and two 100 Mbit/s paths.
# Run only on an idle PVE node: the two data-plane interfaces are shaped and
# one of them is taken down temporarily. A scratch volume is always removed.

set -Eeuo pipefail

STORAGE=${STORAGE:-mptest}
VMID=${VMID:-9912}
VOL=${VOL:-vm-${VMID}-disk-0}
VOLID=${VOLID:-${STORAGE}:${VOL}}
SIZE=${SIZE:-2G}
RATE=${RATE:-100mbit}
RUNTIME=${RUNTIME:-20}
MIN_GAIN=${MIN_GAIN:-1.50}
PATH_A_IFACE=${PATH_A_IFACE:-ens20}
PATH_B_IFACE=${PATH_B_IFACE:-ens21}
TARGET_HOST=${TARGET_HOST:-192.168.34.11}
TARGET_PATH_A_IFACE=${TARGET_PATH_A_IFACE:-ens20}
TARGET_PATH_B_IFACE=${TARGET_PATH_B_IFACE:-ens21}
TARGET_KEY=${TARGET_KEY:-/etc/pve/priv/zfs/${TARGET_HOST}_id_rsa}
RESULTS=${RESULTS:-$(mktemp -d /tmp/zfsiscsimp-perf.XXXXXX)}

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ "${CONFIRM_DESTRUCTIVE:-}" = YES ] || {
    echo "set CONFIRM_DESTRUCTIVE=YES; this writes a scratch volume and changes data-interface qdiscs" >&2
    exit 1
}

for value in "$PATH_A_IFACE" "$PATH_B_IFACE" "$TARGET_PATH_A_IFACE" "$TARGET_PATH_B_IFACE"; do
    [[ "$value" =~ ^[[:alnum:]_.:-]+$ ]] || { echo "invalid interface: $value" >&2; exit 1; }
done
[[ "$RATE" =~ ^[0-9]+(kbit|mbit|gbit)$ ]] || { echo "invalid RATE: $RATE" >&2; exit 1; }
[[ "$MIN_GAIN" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid MIN_GAIN: $MIN_GAIN" >&2; exit 1; }

for command in fio ip tc pvesm multipath perl ssh readlink; do
    command -v "$command" >/dev/null || { echo "missing command: $command" >&2; exit 1; }
done
[ -r "$TARGET_KEY" ] || { echo "target SSH key is not readable: $TARGET_KEY" >&2; exit 1; }
mkdir -p "$RESULTS"

created=0
shaped=0
path_b_down=0
mpath_device=

ssh_target() {
    ssh -i "$TARGET_KEY" -o BatchMode=yes -o ConnectTimeout=10 root@"$TARGET_HOST" "$@"
}

restore_network() {
    if [ "$path_b_down" -eq 1 ]; then
        ip link set "$PATH_B_IFACE" up
        path_b_down=0
    fi
    if [ "$shaped" -eq 1 ]; then
        tc qdisc replace dev "$PATH_A_IFACE" root fq_codel
        tc qdisc replace dev "$PATH_B_IFACE" root fq_codel
        ssh_target "tc qdisc replace dev '$TARGET_PATH_A_IFACE' root fq_codel; tc qdisc replace dev '$TARGET_PATH_B_IFACE' root fq_codel"
        shaped=0
    fi
}

cleanup() {
    rc=$?
    trap - EXIT INT TERM
    restore_network
    if [ "$created" -eq 1 ]; then
        pvesm free "$VOLID" >/dev/null 2>&1 || true
    fi
    echo "RESULTS=$RESULTS"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

local_qdisc_type() {
    tc qdisc show dev "$1" | awk '$4 == "root" { print $2; exit }'
}

for iface in "$PATH_A_IFACE" "$PATH_B_IFACE"; do
    [ "$(local_qdisc_type "$iface")" = fq_codel ] || {
        echo "refusing to replace non-default qdisc on $iface" >&2
        exit 1
    }
done
ssh_target "tc qdisc show dev '$TARGET_PATH_A_IFACE'; tc qdisc show dev '$TARGET_PATH_B_IFACE'" |
    awk '$4 == "root" { print $2 }' | awk '
        $0 != "fq_codel" { bad=1 }
        END { exit (NR == 2 && !bad) ? 0 : 1 }
' || { echo "refusing to replace unexpected target qdisc" >&2; exit 1; }

if pvesm list "$STORAGE" 2>/dev/null | awk '{print $1}' | grep -Fxq "$VOLID"; then
    echo "scratch volume already exists: $VOLID" >&2
    exit 1
fi

pvesm alloc "$STORAGE" "$VMID" "$VOL" "$SIZE" >/dev/null
created=1
perl -e '
    use PVE::Storage;
    my ($storage, $volid) = @ARGV;
    my $cfg = PVE::Storage::config();
    PVE::Storage::activate_volumes($cfg, ["$storage:$volid"]);
' "$STORAGE" "$VOL"

mpath_device=$(readlink -f "$(pvesm path "$VOLID")")
[[ "$(basename "$mpath_device")" == dm-* ]] || {
    echo "volume did not resolve to dm-multipath: $mpath_device" >&2
    exit 1
}

active_paths() {
    multipath -ll "$mpath_device" 2>/dev/null |
        awk '/active[[:space:]]+ready[[:space:]]+running/ { count++ } END { print count + 0 }'
}

wait_paths() {
    expected=$1
    timeout=$2
    for _ in $(seq 1 "$timeout"); do
        [ "$(active_paths)" -eq "$expected" ] && return 0
        sleep 1
    done
    echo "expected $expected active paths, found $(active_paths)" >&2
    multipath -ll "$mpath_device" >&2 || true
    return 1
}

wait_paths 2 45

tc qdisc replace dev "$PATH_A_IFACE" root tbf rate "$RATE" burst 256kb latency 100ms
shaped=1
tc qdisc replace dev "$PATH_B_IFACE" root tbf rate "$RATE" burst 256kb latency 100ms
ssh_target "tc qdisc replace dev '$TARGET_PATH_A_IFACE' root tbf rate '$RATE' burst 256kb latency 100ms; tc qdisc replace dev '$TARGET_PATH_B_IFACE' root tbf rate '$RATE' burst 256kb latency 100ms"

run_fio() {
    label=$1
    operation=$2
    output="$RESULTS/$label.json"
    fio --name="$label" --filename="$mpath_device" --direct=1 --ioengine=libaio \
        --rw="$operation" --bs=1M --iodepth=16 --numjobs=1 --size=1G \
        --runtime="$RUNTIME" --time_based --group_reporting --invalidate=1 \
        --output-format=json --output="$output"
    perl -MJSON=decode_json -0777 -e '
        my ($op) = @ARGV;
        my $json = decode_json(<STDIN>);
        print $json->{jobs}->[0]->{$op}->{bw_bytes};
    ' "$operation" <"$output"
}

echo "scratch=$VOLID device=$mpath_device rate_per_path=$RATE runtime=${RUNTIME}s"
echo "ethtool speed is intentionally irrelevant; tc caps both data directions"

ip link set "$PATH_B_IFACE" down
path_b_down=1
wait_paths 1 45
single_write=$(run_fio single-write write)
single_read=$(run_fio single-read read)

ip link set "$PATH_B_IFACE" up
path_b_down=0
wait_paths 2 60
multi_write=$(run_fio multipath-write write)
multi_read=$(run_fio multipath-read read)

restore_network
wait_paths 2 30

awk -v sw="$single_write" -v sr="$single_read" -v mw="$multi_write" -v mr="$multi_read" \
    -v min="$MIN_GAIN" '
    function mib(v) { return v / 1048576 }
    BEGIN {
        wr = mw / sw;
        rr = mr / sr;
        printf "single_path_write_mib_s=%.2f\n", mib(sw);
        printf "multipath_write_mib_s=%.2f\n", mib(mw);
        printf "write_gain=%.2fx\n", wr;
        printf "single_path_read_mib_s=%.2f\n", mib(sr);
        printf "multipath_read_mib_s=%.2f\n", mib(mr);
        printf "read_gain=%.2fx\n", rr;
        if (wr < min || rr < min) exit 1;
    }
' | tee "$RESULTS/summary.txt"

echo "RATE_LIMITED_PERFORMANCE_OK min_gain=${MIN_GAIN}x"
