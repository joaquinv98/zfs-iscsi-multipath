# Resultados — ZFS over iSCSI con multipath (PoC)

Fecha: 2026-07-13 · Lab: kbuild01 (storage) + pvenest01 (PVE anidado) en hvarres03,
2 portales en VLAN34. Todo efímero, sin tocar producción.

## TL;DR

Funciona. Un plugin de storage custom (`zfsiscsimp`) reemplaza el consumo libiscsi
single-path del plugin `zfs` stock por **kernel initiator + dm-multipath**, y quedó
demostrado end-to-end: alloc, activate, 2 paths activos round-robin, failover sin
pérdida de IO, resize online, y una VM real (cirros) booteando con IO balanceado sobre
los dos portales. Para escrituras secuenciales y lecturas aleatorias el multipath **mejora**
el rendimiento; para escritura aleatoria pura sobre un solo vdev de respaldo no ayuda
(el cuello es el pool, no la red).

## 1. Funcional (capa real de PVE)

| Paso | Resultado |
|---|---|
| `pvesm status` reconoce el storage `zfsiscsimp` | ✅ `mptest zfsiscsimp active` |
| `pvesm alloc` (crea zvol + LUN vía SSH/targetcli) | ✅ `successfully created` |
| WWID: real (`scsi_id`) vs calculado por el plugin | ✅ **idéntico** `36001405ebc0724754674ec8b9c7c7241` |
| `path()` → device multipath estable | ✅ `/dev/disk/by-id/dm-uuid-mpath-<wwid>` |
| `activate_volume` → 2 portales coalescidos | ✅ 1 `dm` con 2 paths `active ready running` |
| `qemu_blockdev_options` en VM real | ✅ `driver: host_device, filename: /dev/disk/by-id/dm-uuid-mpath-...` |

## 2. Performance (fio, 4 jobs, qd32, 12s; device de 4G sobre 1 vdev ZFS)

| Workload | Multipath (2 paths RR) | Single path | Δ |
|---|---|---|---|
| seq read 1M | 2113 MB/s | 2116 MB/s | = (ambos saturan / ARC) |
| seq write 1M | **475 MB/s** | 343 MB/s | **+38% multipath** |
| rand read 4k | **88.0k iops** (344 MB/s) | 59.9k iops (234 MB/s) | **+47% multipath** |
| rand write 4k | 26.4k iops | 34.8k iops | −24% (ver nota) |

Baseline **libiscsi vs multipath** (qemu-img bench, 20000×4k qd32, mismo QEMU block layer):
- libiscsi user-space (1 portal): **0.527 s**
- multipath host_device (kernel, 2 paths): **0.361 s** → **~31% más rápido**

**Nota randwrite**: con un único vdev de respaldo, la escritura aleatoria es sync-bound en
el pool; repartirla en 2 sesiones agrega latencia sin aliviar el cuello, así que rinde
menos. En un pool con varios vdevs / más ancho de banda de red que un solo enlace, la
brecha se invierte. Lo reporto tal cual: multipath no es gratis para todo workload.

## 3. Failover (randwrite 64k, 30s, corte de un portal a t=10s vía iptables DROP)

- `err=0` — **la IO no falló** pese a perder un path.
- Durante el corte: el path bloqueado pasó a `i/o pending`, el otro siguió `active ready
  running`; multipath redirigió todo el tráfico al camino sano.
- Bache de throughput de ~2-3s mientras el path checker (tur) marcó el path caído; luego
  continuó a velocidad de single-path.
- Al restaurar: multipathd re-agregó el path, ambos volvieron a `active ready running`.
- fio completó los 30s (32.4s con el stall), 2819 MiB escritos, sin abortar.

## 4. Lifecycle

- **Resize online 4G → 6G**: `volume_resize` (zvol resize + `iscsiadm --rescan` +
  `multipathd resize map`) → el block device multipath creció a 6 GiB en caliente. ✅
- **VM real (cirros, vmid 8888)**: booteó desde el disco multipath; QEMU con `/dev/dm-2`
  abierto; **IO del guest balanceado sobre los 2 paths** (sdf: 758 rd/313 wr, sdg: 591
  rd/315 wr). ✅

## 4b. Validación con redes FÍSICAMENTE AISLADAS (segunda ronda)

Como todo corre en el mismo nodo hvarres03, se crearon **2 bridges internos de Proxmox**
(`vmbr950`, `vmbr951`) **sin uplink físico**: el tráfico de cada camino nunca sale al switch
real, es todo switching interno del hypervisor. Cada VM recibió una NIC por bridge:

```
kbuild01  ens20=10.90.1.11 (vmbr950 = path A)   ens21=10.90.2.11 (vmbr951 = path B)
pvenest01 ens20=10.90.1.14 (vmbr950)            ens21=10.90.2.14 (vmbr951)
```

Portales LIO en `10.90.1.11` y `10.90.2.11`; el storage `mptest` repuntado a esas IPs.
Las 2 sesiones iSCSI ahora van por caminos **realmente independientes** (distinto bridge),
así que se puede simular un "cable cortado" con `link_down` de la NIC vía API de Proxmox
(equivale a desenchufar el cable de ese switch virtual).

**Corte real de path A durante fio randwrite 90s (link_down 40s):**

| t (s) | path A (sdc) | path B (sdf) | IO |
|---|---|---|---|
| 0–33 | active/ready | active/ready | ambos, ~320 MB/s |
| ~24s tras corte | **failed/faulty** | active/ready | sigue por B (~53→323 MB/s) |
| tras restaurar | failed/ready → **active/ready** | active/ready | ambos de nuevo |

- **fio `err=0`**, 6.09 GB escritos en 90s pese al corte de 40s de un camino.
- El path cortado pasó a `faulty`, el sano absorbió todo el IO, y al volver el link
  multipathd lo reintegró (`active ready running`). Failback verificado.
- También se probó el corte del path B (misma conducta, simétrica).
- IO **balanceado sobre ambos portales** confirmado por los contadores por-sd (reads y
  writes crecen en los dos caminos).

Esto cierra la duda de la ronda anterior (donde ambos portales compartían VLAN34): con
caminos aislados, multipath sobrevive a la pérdida total de un camino sin perder IO.

## 5. Qué falta para producción (no es un drop-in todavía)

- Probar en un nodo PVE real con 2 redes de storage físicamente separadas. En el lab se
  validó con 2 bridges internos aislados (§4b), que prueba la lógica de failover ante corte
  total de un camino; en producción esos 2 caminos deben ser 2 NICs/switches físicos.
- Endurecer: comportamiento ante reboot del target con pool no auto-importado, HA/replica,
  migración en vivo entre 2 nodos con el mismo storage (el flag `shared 1` ya está, falta
  el test multi-nodo).
- Reescribir el manejo de `--rescan` a scan por-LUN para no re-agregar maps de volúmenes
  desactivados (documentado en la review; mitigado con `multipath -w` pero no ideal).
- Considerar NVMe/TCP (`nvmet`) como alternativa: multipath nativo (ANA) sin multipathd.

## Veredicto para NeaTech

El plugin demuestra que el multipath real es viable como plugin custom sin tocar el core de
PVE. Para el caso puntual del cliente (un solo server ZFS), la ganancia grande es
**redundancia de red** (sobrevivir a la caída de un switch/NIC de storage) más un plus de
performance en lecturas y escrituras secuenciales. Para producción conviene: (a) 2 redes de
storage separadas, y (b) una ronda de hardening con los puntos de la sección 5.
