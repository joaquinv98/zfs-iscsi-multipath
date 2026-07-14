#!/bin/bash
# Boot a disposable VM from a dedicated scratch multipath LUN.

VMID=${VMID:-9902}
TEST_SIZE=${TEST_SIZE:-2G}
# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

IMAGE_VERSION=${IMAGE_VERSION:-0.6.3}
IMAGE_DIR=${IMAGE_DIR:-/var/tmp/zfsiscsimp-test-images}
IMAGE=${IMAGE:-$IMAGE_DIR/cirros-${IMAGE_VERSION}-x86_64-disk.img}
BASE_URL=${BASE_URL:-https://download.cirros-cloud.net/$IMAGE_VERSION}
VM_CREATED=0

cleanup() {
    local rc=$?
    set +e
    if [ "$VM_CREATED" -eq 1 ]; then
        qm stop "$VMID" --skiplock 1 --timeout 20 >/dev/null 2>&1 || true
        qm set "$VMID" --delete scsi0 >/dev/null 2>&1 || true
        qm destroy "$VMID" --purge >/dev/null 2>&1 || true
    fi
    cleanup_test_volume "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation
command -v curl >/dev/null || die "curl not found"
command -v qemu-img >/dev/null || die "qemu-img not found"
command -v socat >/dev/null || die "socat not found"
qm status "$VMID" >/dev/null 2>&1 &&
    die "VMID $VMID already exists; choose an unused VMID"

log "download CirrOS $IMAGE_VERSION over HTTPS and verify its published SHA-256"
install -d -m 0755 "$IMAGE_DIR"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$BASE_URL/SHA256SUMS" --output "$IMAGE_DIR/SHA256SUMS"
if [ ! -f "$IMAGE" ]; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$BASE_URL/$(basename "$IMAGE")" --output "$IMAGE.part"
    mv "$IMAGE.part" "$IMAGE"
fi
(
    cd "$IMAGE_DIR" || exit 1
    grep "  $(basename "$IMAGE")$" SHA256SUMS | sha256sum --check --strict -
)

log "allocate $VOLID and copy the verified guest image"
create_test_volume
MP=$(test_map)
WWID=$(test_wwid)
wait_for_paths "$WWID" 2
qemu-img convert -p -f qcow2 -O raw "$IMAGE" "$MP"
sync

log "create and boot disposable VM $VMID from the multipath map"
qm create "$VMID" --name zfsiscsimp-enterprise-test --memory 512 --cores 1 \
    --serial0 socket --vga serial0 --scsihw virtio-scsi-single
VM_CREATED=1
qm set "$VMID" --scsi0 "$VOLID,discard=on,iothread=1,ssd=1"
qm set "$VMID" --boot "order=scsi0"
qm start "$VMID"

for _ in $(seq 1 20); do
    [ "$(qm status "$VMID" | awk '{print $2}')" = running ] && break
    sleep 1
done
[ "$(qm status "$VMID" | awk '{print $2}')" = running ] || die "VM did not reach running state"

PID=$(cat "/run/qemu-server/${VMID}.pid")
DM=$(basename "$(readlink -f "$MP")")
QEMU_OPENED_DM=0
for fd in "/proc/$PID/fd"/*; do
    if [ "$(readlink -f "$fd")" = "/dev/$DM" ]; then
        QEMU_OPENED_DM=1
        break
    fi
done
[ "$QEMU_OPENED_DM" -eq 1 ] || die "QEMU did not open the expected multipath device $DM"

log "capture serial console and require the guest rootfs to start"
CONSOLE=$(mktemp "/tmp/zfsiscsimp-vm-${VMID}.console.XXXXXX")
timeout 45 socat -u "UNIX-CONNECT:/run/qemu-server/${VMID}.serial0" - >"$CONSOLE" &
CAPTURE_PID=$!
BOOT_CONFIRMED=0
for _ in $(seq 1 45); do
    if grep -Eq 'login:|Welcome to CirrOS|initramfs loading root from /dev/sda1' "$CONSOLE"; then
        BOOT_CONFIRMED=1
        break
    fi
    sleep 1
done
kill "$CAPTURE_PID" 2>/dev/null || true
wait "$CAPTURE_PID" 2>/dev/null || true
[ "$BOOT_CONFIRMED" -eq 1 ] || {
    tail -80 "$CONSOLE" >&2
    die "guest boot was not confirmed on the serial console"
}

log "VM_BOOT_OK vmid=$VMID map=$DM console=$CONSOLE"
