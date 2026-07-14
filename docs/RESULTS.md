# Resultados reproducibles — 2026-07-14

Lab anidado: kbuild01 (Ubuntu 24.04, ZFS/LIO) y pvenest01 (PVE 9.2) con caminos
aislados `10.90.1.0/24` y `10.90.2.0/24`. Backend físico lógico: un único vdev.

## Estado final

- PVE kernel `7.0.14-4-pve`; paquetes al día y dpkg limpio.
- Storage kernel `6.8.0-134-generic`; pool sano.
- LIO con ACL explícito, CHAP normal+discovery, 1 mapped LUN principal del lab y
  4 portales. Los zvols de debug `vm-777` y `vm-999` fueron retirados mediante el plugin.
- `mptest` activo, dos sesiones CHAP y 2 paths `active/ready/running` para el LUN activo.
- Política de volúmenes nuevos en 16 KiB, verificada con alloc/activate/free y sin paths
  stale. `vm-888` conserva sus 4 KiB originales porque el `volblocksize` es inmutable.
- `systemctl --failed`: vacío en ambos hosts.
- Scrub final de `tank`: 0 B reparados, 0 errores. Reboot final del initiator: journal
  nivel `err` vacío, dos sesiones y dos paths restaurados.

## Funcional y seguridad

| Prueba | Resultado |
|---|---|
| alloc/activate/deactivate/free | PASS |
| 512 MiB CRC, snapshot, mutación, rollback, WWID nuevo | PASS |
| resize online 3→4 GiB y tamaño dm verificado | PASS |
| scan de otro LUN no resucita mapa inactivo | PASS |
| free sin mapa + reutilización inmediata del número de LUN | PASS; sin paths stale |
| VM CirrOS 0.6.3 con SHA-256 oficial, QEMU sobre dm y rootfs iniciado | PASS |
| discovery sin CHAP | rechazado |
| login sin CHAP con el otro path activo | rechazado |
| control-plane SSH con primary black-holed | read 8 s; mutación 5 s; PASS |
| `bash -n`, `shellcheck`, Perl y loader PVE/API 15 | PASS |

## Reliability con fio+CRC

Los casos escriben headers CRC32C, ejecutan carga mixta y releen todo el rango después de
recuperar. Un error fio, CRC, path o SLA hace fallar el script.

| Evento | fio | max clat | Resultado |
|---|---:|---:|---|
| path A DROP 15 s | err=0 | 7.145 s | PASS (<8 s) |
| path B DROP 15 s | err=0 | 6.112 s | PASS (<8 s) |
| A+B DROP 8 s | err=0 | 12.686 s | PASS (<16 s) |
| reboot completo de kbuild01 | err=0 | 25.749 s | PASS (<30 s) |

El reboot restauró pool, target, ACL/CHAP y ambos paths. La cola sin paths es finita
(~60 s); una caída mayor debe considerarse error del storage, no failover de controladora.

## Performance

Mismo zvol `vm-888` de 4 KiB y mismo dm-map, 4 jobs, QD8 cada uno (QD32 total),
10 s, 2 repeticiones.

| Workload | 2 paths | 1 path | p99 2p / 1p |
|---|---:|---:|---:|
| read 1M | 1393.6 MB/s | 1510.5 MB/s | 50.6 / 33.4 ms |
| write 1M | 102.3 MB/s | 121.4 MB/s | 3724.5 / 3187.7 ms |
| randread 4K | 60.8k IOPS | 63.8k IOPS | 1.092 / 0.979 ms |
| randwrite 4K | 10.3k IOPS | 10.9k IOPS | 1.491 / 1.245 ms |

Multipath fue 4–16% más lento aquí: ambos portales terminan en el mismo target y el mismo
vdev, por lo que no agregan capacidad física y sí agregan scheduling. La ganancia demostrada
es disponibilidad de red. El p99 de write secuencial refleja saturación/colas del backend
anidado; no es una cifra de dimensionamiento.

### Cada fabric limitado a 100 Mbit/s

Las NIC `virtio_net` no permiten fijar velocidad con `ethtool`. El test aplicó TBF a
100 Mbit/s sobre `ens20` y `ens21` tanto en initiator como target (egress en ambos extremos),
sin tocar management. Para single-path bloqueó el portal B y exigió exactamente un path
usable; esto evita que `pvestatd` invalide la prueba relogueando una sesión.

4 jobs, QD8 cada uno, 20 s y 2 repeticiones válidas:

| Workload | 2×100 Mbit/s | 1×100 Mbit/s | Ratio | p99 2p / 1p |
|---|---:|---:|---:|---:|
| read 1M | 23.916 MB/s | 11.935 MB/s | 2.004× | 2315 / 4832 ms |
| write 1M | 23.895 MB/s | 11.960 MB/s | 1.998× | 2298 / 4429 ms |
| randread 4K | 23.498 MB/s | 11.774 MB/s | 1.996× | 7.930 / 12.517 ms |
| randwrite 4K | 23.516 MB/s | 11.751 MB/s | 2.001× | 6.619 / 11.469 ms |

Con un cuello independiente por fabric, multipath agregó prácticamente el 100% del segundo
enlace. Los p99 secuenciales altos son esperables con QD32 y bloques de 1 MiB contra links
de 100 Mbit/s: hay decenas de MiB pendientes detrás del shaper.

## Cluster de 2 nodos y migración en vivo (2026-07-14)

Se montó un cluster PVE real de 2 nodos anidados (`pvenest01` .34.14, `pvenest02` .34.16,
`pvecm` Quorate) contra el mismo target. pmxcfs propagó `storage.cfg`, el secreto CHAP y las
llaves SSH del plugin automáticamente a `pvenest02`. Cada nodo tiene su propio IQN con una
ACL dedicada en el target (mismo CHAP) — se confirmó que **un nodo por IQN** es lo correcto.

| Prueba | Resultado |
|---|---|
| `pvecm` cluster 2 nodos, Quorate | PASS |
| propagación storage.cfg + CHAP + llaves vía pmxcfs | PASS |
| ACL+CHAP por IQN de nodo, ambos nodos activan `mptest` | PASS |
| migración en vivo (shared storage, sin copiar disco) | PASS, downtime 2 ms, 1.8 MiB estado |
| migración en vivo **bajo IO del guest** (cirros escribiendo) | PASS, downtime 15 ms, 137 MiB estado |
| teardown del origen tras migrar (map + sd devices) | PASS, 0 residual en ambos sentidos |
| migración a nodo con **1 path caído** (destino degradado) | PASS, VM aterriza y corre con 1 path |
| recuperación del path restaurado (re-activación) | PASS, vuelve a 2 paths `active/ready` |
| IO del guest balanceado en ambos paths tras migrar | PASS (writes crecen en los 2 sd) |

**Bug encontrado y corregido en este test**: la primera migración bajo carga dejó el map del
origen colgado (`teardown did not complete`) porque la ventana de flush del `deactivate_volume`
(5×300 ms) era muy corta para la carrera del cleanup (QEMU recién salido + udev). Se amplió a
un backoff de ~15 s; tras el fix, ambos sentidos de migración limpian el origen a 0 residual.
También se corrigieron, a partir de la review adversarial de 0.2.0: `read_saveconfig` sin
timeout (colgó un `activate` en `pvenest02` con la red aún sin configurar), el hook de update
que borraba el secreto CHAP antes de validar, el teardown que confundía "no identificable" con
"map en uso" (volumen huérfano no se podía liberar), y el pin estricto de API en el instalador.

**Limitación observada (menor)**: tras restaurar un path caído, el re-login de la sesión lo
hace `activate_storage`, pero el path no vuelve al map hasta la siguiente `activate_volume`
(rescan por-LUN) o hasta que el path checker de multipathd descubra el nuevo device. Se
autorresuelve, pero no es instantáneo.

## Kernel patch

- Runtime GET LBA STATUS: 8 passed, 0 failed.
- libiscsi: 2304/2304 asserts; ReadCapacity16 y Unmap sin regresiones.
- `qemu-img map`: extents sparse sin `GET_LBA_STATUS failed`.
- `qemu-img convert`: contenido bit a bit y archivo sparse.

## Riesgos que no cierra este lab

- SPOF del host/pool LIO único (para HA real de storage: 2 controladoras/targets o backend
  distribuido). Esto es arquitectónico, no del plugin.
- Todo en un solo host físico (hvarres03) con bridges internos: la agregación real y el
  aislamiento de fallas de red necesitan 2 NICs/switches físicos.
- Comportamiento y capacidad en NICs, switches y vdevs físicos del destino.
- Compatibilidad futura del plugin custom después de un cambio de API de PVE (el instalador
  ahora valida contra la ventana APIVER/APIAGE, pero cada upgrade de PVE requiere re-verificar).
