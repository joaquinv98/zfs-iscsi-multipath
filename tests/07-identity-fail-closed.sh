#!/bin/bash
# Prove that complete control-plane loss cannot be mistaken for an absent LUN.

VMID=${VMID:-9907}
TEST_SIZE=${TEST_SIZE:-1G}
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

WORKDIR=$(mktemp -d /tmp/zfsiscsimp-failclosed.XXXXXX)
PAYLOAD="$WORKDIR/payload.bin"
READBACK="$WORKDIR/readback.bin"

cleanup() {
    local rc=$?
    set +e
    remove_drop_rules
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
create_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 2 45

log "write a checksum marker before isolating both control/data portals"
dd if=/dev/urandom of="$PAYLOAD" bs=1M count=64 status=none
EXPECTED=$(sha256sum "$PAYLOAD" | awk '{print $1}')
dd if="$PAYLOAD" of="$MP" bs=1M oflag=direct conv=fsync status=none

log "black-hole every portal and require free_image to fail closed"
drop_portal "$PORTAL_A"
drop_portal "$PORTAL_B"
if pvesm free "$VOLID" >"$WORKDIR/free.out" 2>&1; then
    die "free unexpectedly succeeded while every identity source was unavailable"
fi
grep -Eq "identity state is unknown|unable to read the LIO saveconfig" "$WORKDIR/free.out" || {
    cat "$WORKDIR/free.out" >&2
    die "free failed for an unexpected reason"
}

log "restore control plane; volume and data must still exist"
remove_drop_rules
pvesm list "$STORAGE" --vmid "$VMID" | awk -v id="$VOLID" '$1 == id { found=1 } END { exit !found }' ||
    die "scratch volume disappeared after the rejected free"
activate_test_volume
wait_for_paths "$WWID" 2 45
dd if="$MP" of="$READBACK" bs=1M count=64 iflag=direct status=none
ACTUAL=$(sha256sum "$READBACK" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || die "data checksum changed across rejected destructive operation"

echo "IDENTITY_FAIL_CLOSED_OK volid=$VOLID wwid=$WWID sha256=$ACTUAL"
