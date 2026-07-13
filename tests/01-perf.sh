#!/bin/bash
# Test battery for the zfsiscsimp multipath storage, run on pvenest01 (initiator).
# Storage 'mptest' registered; target on kbuild01 has 2 portals (.11 primary, .13 extra).
set -u
STORAGE=mptest
VOL=vm-888-disk-0
VOLID="$STORAGE:$VOL"
SIZE=4G
STORAGE_HOST=192.168.34.11
PORTAL2=192.168.34.13
line(){ echo; echo "======== $* ========"; }

line "0. alloc + activate volumen de prueba ($SIZE)"
sudo pvesm alloc "$STORAGE" 888 "$VOL" "$SIZE" 2>&1 | grep -v volblocksize | tail -1
sudo perl -e 'use PVE::Storage; my $c=PVE::Storage::config(); PVE::Storage::activate_volumes($c,["'"$VOLID"'"]);'
MP=$(sudo pvesm path "$VOLID")
DM=$(readlink -f "$MP")
SD1=$(ls /sys/block/$(basename "$DM")/slaves | head -1)
SINGLE="/dev/$SD1"
LUN=$(sudo perl -e 'use PVE::Storage; my $c=PVE::Storage::config(); my $s=PVE::Storage::storage_config($c,"mptest"); my $g=PVE::Storage::Custom::ZFSiSCSIMPPlugin->zfs_get_lu_name($s,"'"$VOL"'"); print PVE::Storage::Custom::ZFSiSCSIMPPlugin->zfs_get_lun_number($s,$g);' 2>/dev/null)
URL="iscsi://$STORAGE_HOST/iqn.2026-07.ar.ntc:kbuild01-tank/$LUN"
echo "multipath=$MP  single=$SINGLE  lun=$LUN"
echo "paths:"; sudo multipath -ll "$MP" | grep -E "running|failed"

fio_run(){ # $1=dev $2=rw $3=bs $4=label
  sudo fio --name="$4" --filename="$1" --direct=1 --ioengine=libaio --rw="$2" --bs="$3" \
    --iodepth=32 --numjobs=4 --runtime=12 --time_based --group_reporting --norandommap \
    --output-format=terse --terse-version=3 2>/dev/null | awk -F';' '
    { rbw=$7; riops=$8; wbw=$48; wiops=$49;
      printf "  %-24s R:%8.1f MB/s %7d iops   W:%8.1f MB/s %7d iops\n", "'"$4"'", rbw/1024, riops, wbw/1024, wiops }'
}

line "1. PERFORMANCE fio: multipath (2 paths RR) vs single path (kernel)"
for rw in read write randread randwrite; do
  bs=$([ "${rw#rand}" != "$rw" ] && echo 4k || echo 1M)
  fio_run "$MP"     "$rw" "$bs" "mpath-$rw"
  fio_run "$SINGLE" "$rw" "$bs" "single-$rw"
done

line "2. BASELINE libiscsi (plugin stock) vs multipath host_device, mismo QEMU block layer"
echo "-- libiscsi user-space (1 portal), qemu-img bench write 4k x20000 qd32 --"
sudo qemu-img bench -f raw -t none -n -c 20000 -d 32 -s 4096 -w "$URL" 2>&1 | grep -iE "completed" || echo "(fallo)"
echo "-- multipath host_device (kernel, 2 paths) --"
sudo qemu-img bench -f raw -t none -n -c 20000 -d 32 -s 4096 -w "$MP" 2>&1 | grep -iE "completed" || echo "(fallo)"

line "3. FAILOVER bajo carga: randwrite 30s, matamos portal $PORTAL2 a t=10s"
rm -f /tmp/fo_bw.1.log
sudo fio --name=failover --filename="$MP" --direct=1 --ioengine=libaio --rw=randwrite --bs=4k \
  --iodepth=16 --numjobs=1 --runtime=30 --time_based --eta=never \
  --write_bw_log=/tmp/fo --log_avg_msec=500 >/tmp/fio_fo.out 2>&1 &
FIO_PID=$!
sleep 10
echo "[t=10] paths:"; sudo multipath -ll "$MP" | grep -E "running|failed|faulty"
echo "[t=10] >>> ip link set ens19 down en el storage (mata portal $PORTAL2) <<<"
ssh -i /etc/pve/priv/zfs/${STORAGE_HOST}_id_rsa -o BatchMode=yes root@$STORAGE_HOST "ip link set ens19 down" 2>&1 || echo "(fallo bajar NIC)"
sleep 9
echo "[t=19] paths (un portal caido):"; sudo multipath -ll "$MP" | grep -E "running|failed|faulty"
echo "[t=19] fio vivo? $(kill -0 $FIO_PID 2>/dev/null && echo SI || echo NO)"
echo "[t=19] >>> restaurando portal $PORTAL2 <<<"
ssh -i /etc/pve/priv/zfs/${STORAGE_HOST}_id_rsa -o BatchMode=yes root@$STORAGE_HOST "ip link set ens19 up; ip addr add 192.168.34.13/24 dev ens19 2>/dev/null; true" 2>&1 || true
sudo iscsiadm -m node -T iqn.2026-07.ar.ntc:kbuild01-tank -p $PORTAL2:3260 --login 2>&1 | tail -1 || true
wait $FIO_PID 2>/dev/null
echo "-- fio failover result --"
grep -iE "err= |IOPS=|io=" /tmp/fio_fo.out | head -4
sleep 3
echo "[post] paths recuperados:"; sudo multipath -ll "$MP" | grep -E "running|failed"

line "3b. gap de IO durante failover (MB/s cada 500ms alrededor del corte)"
if [ -f /tmp/fo_bw.1.log ]; then
  awk -F',' '{mb=$2/1024; t=$1/1000; if(t>=7 && t<=24) printf "  t=%5.1fs  %7.1f MB/s%s\n", t, mb, (mb<0.5?"  <== GAP":"")}' /tmp/fo_bw.1.log
fi

echo "TESTS_DONE (volumen $VOLID queda para el test de VM/resize)"
