#!/bin/bash
# Prove SSH control-plane failover while the primary data/control portal is black-holed.

VMID=${VMID:-9903}
TEST_SIZE=${TEST_SIZE:-1G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

cleanup() {
    local rc=$?
    set +e
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation

log "black-hole primary portal $PORTAL_A"
drop_portal "$PORTAL_A"
START=$SECONDS
pvesm status --storage "$STORAGE"
pvesm list "$STORAGE" >/dev/null
READ_FAILOVER_SECONDS=$((SECONDS - START))
[ "$READ_FAILOVER_SECONDS" -le 8 ] ||
    die "read-only control-plane failover took ${READ_FAILOVER_SECONDS}s (limit: 8s)"

log "allocate a scratch LUN through the secondary SSH portal"
START=$SECONDS
pvesm alloc "$STORAGE" "$VMID" "$VOL" "$TEST_SIZE"
export OWN_TEST_VOLUME=1
MUTATION_FAILOVER_SECONDS=$((SECONDS - START))
[ "$MUTATION_FAILOVER_SECONDS" -le 12 ] ||
    die "mutating control-plane failover took ${MUTATION_FAILOVER_SECONDS}s (limit: 12s)"
activate_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 1 30
fio --name=control-failover --filename="$MP" --size=128M --direct=1 \
    --ioengine=libaio --rw=write --bs=128k --iodepth=8 --verify=crc32c \
    --verify_fatal=1 --do_verify=1 --group_reporting

log "restore primary and require both data paths"
remove_drop_rules
activate_test_volume
wait_for_paths "$WWID" 2 45

echo "CONTROL_PLANE_OK read_failover_s=$READ_FAILOVER_SECONDS mutation_failover_s=$MUTATION_FAILOVER_SECONDS"
