#!/bin/bash
# Shared helpers for destructive zfsiscsimp integration tests.

set -Eeuo pipefail

STORAGE=${STORAGE:-mptest}
VMID=${VMID:-9901}
VOL=${VOL:-vm-${VMID}-disk-0}
VOLID=${STORAGE}:${VOL}
TARGET=${TARGET:-iqn.2026-07.ar.ntc:kbuild01-tank}
PORTAL_A=${PORTAL_A:-10.90.1.11}
PORTAL_B=${PORTAL_B:-10.90.2.11}
TEST_SIZE=${TEST_SIZE:-4G}
KEEP_TEST_VOLUME=${KEEP_TEST_VOLUME:-0}
OWN_TEST_VOLUME=0

log() { printf '\n===== %s =====\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_test_confirmation() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ "${CONFIRM_DESTRUCTIVE:-}" = "YES" ] ||
        die "set CONFIRM_DESTRUCTIVE=YES; this test overwrites a dedicated scratch LUN"
    command -v pvesm >/dev/null || die "pvesm not found"
    command -v fio >/dev/null || die "fio not found"
    pvesm status --storage "$STORAGE" | grep -qE "^${STORAGE}[[:space:]].*active" ||
        die "storage '$STORAGE' is not active"
}

volume_exists() {
    pvesm list "$STORAGE" --vmid "$VMID" 2>/dev/null | awk -v id="$VOLID" '$1 == id { found=1 } END { exit !found }'
}

create_test_volume() {
    if volume_exists; then
        die "scratch volume '$VOLID' already exists; choose another VMID or remove it explicitly"
    fi
    pvesm alloc "$STORAGE" "$VMID" "$VOL" "$TEST_SIZE"
    OWN_TEST_VOLUME=1
    activate_test_volume
}

activate_test_volume() {
    VOLID="$VOLID" perl -MPVE::Storage -e '
        my $cfg = PVE::Storage::config();
        PVE::Storage::activate_volumes($cfg, [$ENV{VOLID}]);
    '
}

deactivate_test_volume() {
    VOLID="$VOLID" perl -MPVE::Storage -e '
        my $cfg = PVE::Storage::config();
        PVE::Storage::deactivate_volumes($cfg, [$ENV{VOLID}]);
    '
}

test_map() {
    pvesm path "$VOLID"
}

test_wwid() {
    local map dm_uuid
    map=$(test_map)
    dm_uuid=$(udevadm info --query=property --name "$map" | awk -F= '$1 == "DM_UUID" { print $2 }')
    [[ "$dm_uuid" == mpath-* ]] || die "'$map' is not a multipath map"
    printf '%s\n' "${dm_uuid#mpath-}"
}

usable_paths() {
    local wwid=$1
    multipathd show paths raw format '%w|%t|%o|%T' |
        awk -F'|' -v w="$wwid" '$1 == w && $2 == "active" && $3 == "running" && $4 == "ready" { n++ } END { print n+0 }'
}

wait_for_paths() {
    local wwid=$1 expected=$2 timeout=${3:-30} start=$SECONDS count
    while (( SECONDS - start < timeout )); do
        count=$(usable_paths "$wwid")
        [ "$count" -ge "$expected" ] && return 0
        sleep 1
    done
    multipath -ll "$wwid" >&2 || true
    die "WWID $wwid did not reach $expected usable paths within ${timeout}s"
}

wait_for_no_map() {
    local wwid=$1 timeout=${2:-15} start=$SECONDS
    while (( SECONDS - start < timeout )); do
        [ ! -e "/dev/disk/by-id/dm-uuid-mpath-$wwid" ] && return 0
        sleep 0.5
    done
    die "multipath map $wwid still exists after teardown"
}

remove_drop_rules() {
    local portal
    for portal in "$PORTAL_A" "$PORTAL_B"; do
        while iptables -C OUTPUT -d "$portal" -m comment --comment zfsiscsimp-test -j DROP 2>/dev/null; do
            iptables -D OUTPUT -d "$portal" -m comment --comment zfsiscsimp-test -j DROP || true
        done
        while iptables -C INPUT -s "$portal" -m comment --comment zfsiscsimp-test -j DROP 2>/dev/null; do
            iptables -D INPUT -s "$portal" -m comment --comment zfsiscsimp-test -j DROP || true
        done
    done
}

drop_portal() {
    local portal=$1
    iptables -I OUTPUT -d "$portal" -m comment --comment zfsiscsimp-test -j DROP
    iptables -I INPUT -s "$portal" -m comment --comment zfsiscsimp-test -j DROP
}

cleanup_test_volume() {
    local rc=${1:-$?}
    set +e
    remove_drop_rules
    if [ "$OWN_TEST_VOLUME" -eq 1 ] && [ "$KEEP_TEST_VOLUME" -ne 1 ]; then
        deactivate_test_volume >/dev/null 2>&1 || true
        pvesm free "$VOLID" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
