#!/bin/bash
# End-to-end allocation, integrity, snapshot rollback, resize and exact-LUN scan test.

TEST_SIZE=${TEST_SIZE:-3G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

SNAP=${SNAP:-enterprise-check}
CONTROL_VOLID=${CONTROL_VOLID:-mptest:vm-888-disk-0}
CONTROL_TOUCHED=0
SNAP_EXISTS=0

cleanup() {
    local rc=$?
    set +e
    if [ "$SNAP_EXISTS" -eq 1 ]; then
        VOLID="$VOLID" SNAP="$SNAP" perl -MPVE::Storage -e '
            my $cfg = PVE::Storage::config();
            eval { PVE::Storage::volume_snapshot_delete($cfg, $ENV{VOLID}, $ENV{SNAP}, 0) };
        ' >/dev/null 2>&1 || true
    fi
    if [ "$CONTROL_TOUCHED" -eq 1 ]; then
        VOLID="$CONTROL_VOLID" perl -MPVE::Storage -e '
            my $cfg = PVE::Storage::config();
            eval { PVE::Storage::activate_volumes($cfg, [$ENV{VOLID}]) };
        ' >/dev/null 2>&1 || true
    fi
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
log "allocate and activate $VOLID"
create_test_volume
MP=$(test_map)
OLD_WWID=$(test_wwid)
wait_for_paths "$OLD_WWID" 2
multipath -ll "$OLD_WWID"

log "write and verify a CRC-protected seed"
fio --name=seed --filename="$MP" --offset=0 --size=512M --direct=1 --ioengine=libaio \
    --rw=write --bs=128k --iodepth=16 --verify=crc32c --verify_fatal=1 --do_verify=1 \
    --group_reporting

log "snapshot, mutate, rollback and verify original data"
VOLID="$VOLID" SNAP="$SNAP" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    PVE::Storage::volume_snapshot($cfg, $ENV{VOLID}, $ENV{SNAP});
'
SNAP_EXISTS=1

fio --name=mutated --filename="$MP" --offset=0 --size=512M --direct=1 --ioengine=libaio \
    --rw=write --bs=128k --iodepth=16 --verify=crc32c --verify_fatal=1 --do_verify=1 \
    --group_reporting

deactivate_test_volume
wait_for_no_map "$OLD_WWID"
VOLID="$VOLID" SNAP="$SNAP" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    PVE::Storage::volume_snapshot_rollback($cfg, $ENV{VOLID}, $ENV{SNAP});
'
activate_test_volume
MP=$(test_map)
NEW_WWID=$(test_wwid)
wait_for_paths "$NEW_WWID" 2
[ "$NEW_WWID" != "$OLD_WWID" ] || die "rollback recreated LIO backstore without changing WWID as expected"

fio --name=seed --filename="$MP" --offset=0 --size=512M --direct=1 --ioengine=libaio \
    --rw=read --bs=128k --iodepth=16 --verify=crc32c --verify_fatal=1 --verify_only=1 \
    --group_reporting

VOLID="$VOLID" SNAP="$SNAP" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    PVE::Storage::volume_snapshot_delete($cfg, $ENV{VOLID}, $ENV{SNAP}, 0);
'
SNAP_EXISTS=0

log "online resize to 4 GiB and verify dm size"
VOLID="$VOLID" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    PVE::Storage::volume_resize($cfg, $ENV{VOLID}, 4 * 1024 * 1024 * 1024, 1);
'
[ "$(blockdev --getsize64 "$MP")" -eq $((4 * 1024 * 1024 * 1024)) ] ||
    die "multipath map did not reach 4 GiB"

log "deactivate scratch map and prove another LUN scan does not resurrect it"
deactivate_test_volume
wait_for_no_map "$NEW_WWID"
if pvesm list "${CONTROL_VOLID%%:*}" | awk -v id="$CONTROL_VOLID" '$1 == id { found=1 } END { exit !found }'; then
    CONTROL_TOUCHED=1
    VOLID="$CONTROL_VOLID" perl -MPVE::Storage -e '
        my $cfg = PVE::Storage::config();
        PVE::Storage::deactivate_volumes($cfg, [$ENV{VOLID}]);
        PVE::Storage::activate_volumes($cfg, [$ENV{VOLID}]);
    '
    [ ! -e "/dev/disk/by-id/dm-uuid-mpath-$NEW_WWID" ] ||
        die "exact-LUN activation resurrected deactivated scratch map"
fi

log "SMOKE_LIFECYCLE_OK"
