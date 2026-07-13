#!/bin/bash
# Failover test: block one portal with iptables mid-fio, observe multipath switch.
# Run with sudo on pvenest01.
set -u
MP=$(pvesm path mptest:vm-888-disk-0)
PORTAL2=192.168.34.13
W=$(mktemp -d /tmp/fotest.XXXXXX); cd "$W"
echo "workdir: $W"
echo "multipath dev: $MP"
echo "paths iniciales:"; multipath -ll "$MP" | grep -E "running|failed|faulty"

fio --name=failover --filename="$MP" --direct=1 --ioengine=libaio --rw=randwrite --bs=64k \
  --iodepth=16 --numjobs=1 --runtime=30 --time_based --eta=never \
  --write_bw_log="$W/fo" --log_avg_msec=250 >"$W/fio_fo.out" 2>&1 &
FIO_PID=$!
sleep 2
echo "fio arrancado (pid $FIO_PID), vivo? $(kill -0 $FIO_PID 2>/dev/null && echo SI || echo 'NO - abortar')"
kill -0 $FIO_PID 2>/dev/null || { echo '--- fio no arranco ---'; cat "$W/fio_fo.out"; exit 1; }

sleep 8
echo "[t=10] >>> iptables DROP hacia portal $PORTAL2 (simula caida de un path) <<<"
iptables -A OUTPUT -d $PORTAL2 -j DROP
iptables -A INPUT  -s $PORTAL2 -j DROP
T_DOWN=$SECONDS
sleep 10
echo "[t=20] paths con portal $PORTAL2 bloqueado:"
multipath -ll "$MP" | grep -E "running|failed|faulty"
echo "[t=20] fio vivo? $(kill -0 $FIO_PID 2>/dev/null && echo SI || echo NO)"
echo "[t=20] >>> restaurando portal $PORTAL2 <<<"
iptables -D OUTPUT -d $PORTAL2 -j DROP
iptables -D INPUT  -s $PORTAL2 -j DROP
wait $FIO_PID 2>/dev/null
echo
echo "-- resultado fio (err debe ser 0; IO completa pese al corte) --"
grep -iE "err= |IOPS=|WRITE:" "$W/fio_fo.out" | head -4
sleep 4
echo "-- paths tras restaurar (multipathd re-agrega el path) --"
multipath -ll "$MP" | grep -E "running|failed|faulty"
echo
echo "-- perfil de BW durante el corte (MB/s cada 250ms, t=8..16s) --"
awk -F',' '{mb=$2/1024; t=$1/1000; if(t>=8 && t<=16) printf "  t=%6.2fs  %7.1f MB/s%s\n", t, mb, (mb<1?"  <== GAP":"")}' "$W"/fo_bw.1.log
echo "FAILOVER_DONE"
