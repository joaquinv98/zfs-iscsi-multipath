#!/bin/bash
# Resize test + real VM booting off the multipath ZFS-over-iSCSI disk. sudo on pvenest01.
set -u
VOLID=mptest:vm-888-disk-0
line(){ echo; echo "======== $* ========"; }

line "A. RESIZE online 4G -> 6G (via pvesm/PVE::Storage)"
BEFORE=$(perl -e 'use PVE::Storage; my $c=PVE::Storage::config(); print +(PVE::Storage::volume_size_info($c,"'"$VOLID"'"))[0];')
echo "size antes: $((BEFORE/1024/1024/1024)) GiB"
perl -e 'use PVE::Storage; my $c=PVE::Storage::config(); PVE::Storage::volume_resize($c,"'"$VOLID"'", 6*1024*1024*1024, 0);'
sleep 2
MP=$(pvesm path "$VOLID")
echo "multipath tras resize:"; multipath -ll "$MP" | grep dm-
BLKSZ=$(blockdev --getsize64 "$MP" 2>/dev/null)
echo "tamano del block device multipath ahora: $((BLKSZ/1024/1024/1024)) GiB (esperado 6)"

line "B. VM real (8888) booteando cirros desde el disco multipath"
cd /tmp
if [ ! -f cirros.img ]; then
  echo "-- bajando cirros (imagen minima booteable) --"
  wget -q https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img -O cirros.img || \
  wget -q http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img -O cirros.img
fi
ls -la cirros.img 2>/dev/null || { echo "no pude bajar cirros; salto boot"; exit 0; }
echo "-- escribiendo cirros al disco multipath (qemu-img convert al /dev/mapper) --"
qemu-img convert -O raw cirros.img "$MP"
sync

qm destroy 8888 --purge 2>/dev/null || true
echo "-- qm create 8888 con scsi0 = $VOLID --"
qm create 8888 --name mptest-guest --memory 512 --cores 1 --serial0 socket --vga serial0 \
  --scsihw virtio-scsi-pci --net0 virtio,bridge=vmbr0 2>&1 | tail -2 || \
qm create 8888 --name mptest-guest --memory 512 --cores 1 --serial0 socket --vga serial0 \
  --scsihw virtio-scsi-pci 2>&1 | tail -2
qm set 8888 --scsi0 "$VOLID" 2>&1 | tail -1
qm set 8888 --boot order=scsi0 2>&1 | tail -1
echo "-- config de la VM (el disco debe ser el storage multipath) --"
qm config 8888 | grep -E "scsi0|boot"
echo "-- el blockdev que QEMU va a usar (qemu_blockdev_options del plugin) --"
qm showcmd 8888 2>/dev/null | tr ' ' '\n' | grep -A1 -iE "blockdev|drive|mapper|by-id" | grep -iE "mapper|by-id|host_device|file=" | head -5

echo "-- arrancar la VM --"
qm start 8888 2>&1 | tail -2
sleep 25
echo "-- estado + verificacion de que QEMU abrio el device multipath --"
qm status 8888
PID=$(cat /var/run/qemu-server/8888.pid 2>/dev/null)
if [ -n "$PID" ]; then
  echo "qemu pid $PID; block backends multipath abiertos:"
  ls -l /proc/$PID/fd 2>/dev/null | grep -iE "dm-|mapper" | head
  grep -c "$(basename $(readlink -f "$MP"))" /proc/$PID/maps 2>/dev/null || true
fi
echo "-- consola serial: primeras lineas de boot del guest (prueba que bootea del disco) --"
timeout 20 qm terminal 8888 2>/dev/null <<< "" | head -30 || \
  (echo "" | timeout 15 socat - UNIX-CONNECT:/var/run/qemu-server/8888.serial0 2>/dev/null | head -30) || \
  echo "(no pude capturar la consola; el estado running + fd abierto ya prueban el uso del disco)"
echo "VM_TEST_DONE"
