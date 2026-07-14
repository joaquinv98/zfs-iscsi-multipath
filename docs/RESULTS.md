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

El gate autocontenido `tests/10-rate-limited-performance.sh` repitió la condición al cerrar
0.3.2: write 11.41→22.81 MiB/s y read 11.40→22.76 MiB/s, exactamente 2.00× en ambos casos.
El primer intento además validó el rollback del test: ante un error de parser restauró link
y qdiscs y eliminó el zvol scratch sin dejar maps.

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

### HA real: recuperación automática ante muerte de nodo (2026-07-14)

Se agregó un **QDevice** (`corosync-qnetd` en kbuild01) como tercer voto para que el cluster
de 2 nodos mantenga quórum al perder uno (Expected votes 3, Quorum 2). VM 8888 se puso como
recurso HA (`ha-manager add vm:8888 --state started`), watchdog `softdog` armado en ambos nodos.

Prueba de fuego: **power-off duro de pvenest01** (vía API de Proxmox, con la VM corriendo ahí
y el guest escribiendo). Timeline observado desde pvenest02:

| t (s) | evento |
|---|---|
| 0 | pvenest01 muere; pvenest02 + QDevice siguen Quorate (2/3) |
| ~144 | fence completado; HA relocaliza `vm:8888` a pvenest02 (`starting`) |
| ~150–300 | `qm start` FALLA en loop → servicio en estado `error` |
| (fix) | reinicio de `pve-ha-lrm`/`pve-ha-crm` → recuperación exitosa, VM `started` con 2 paths |

**Bug production-critical encontrado (solo aparece en HA real)**: el `qm start` de la
recuperación falló con `unsupported type 'zfsiscsimp' ... storage 'mptest' does not exist`. El
daemon `pve-ha-lrm` (el que arranca la VM en el failover HA) había cacheado el registro de
plugins de `PVE::Storage` al iniciar y **no conocía el plugin custom** — el `install.sh`
reiniciaba pvedaemon/pveproxy/pvestatd/pvescheduler pero NO los daemons HA. Por eso la
migración manual (disparada por pvedaemon, que sí se reinicia) funcionaba y el recovery HA no.
Corregido: `install.sh` ahora reinicia también `pve-ha-lrm` y `pve-ha-crm`. Tras el fix, la VM
revive sola en el nodo superviviente con su disco multipath y 2 paths, y el guest cirros
bootea en frío (power-cycle crash-consistent, no resume — lo esperado en HA).

Resumen HA:

| Prueba | Resultado |
|---|---|
| QDevice 3er voto, quórum sobrevive a muerte de nodo | PASS |
| fencing del nodo muerto (watchdog softdog) | PASS (~144 s) |
| relocalización + `qm start` del recurso HA | PASS (tras reiniciar daemons HA) |
| VM recuperada con disco multipath y 2 paths | PASS |
| guest cold-boot en el nodo superviviente | PASS |

## Upgrade hardening 0.3.0–0.3.3 (2026-07-14)

El rollout se hizo rolling sobre el mismo cluster, manteniendo `vm:8888` en el nodo opuesto
durante instalación/reboot y usándola como canario de migración al terminar.

| Prueba | Resultado |
|---|---|
| Perl real PVE + `bash -n` + `shellcheck` | PASS, sin hallazgos |
| contrato upstream certificado (commit `d666ebd6`, API 15/age 6) | PASS |
| build Debian `pve-storage-zfsiscsimp_0.3.3_all.deb` | PASS |
| preflight local en ambos nodos | PASS, 0 warnings |
| preflight cluster (versión/API/SHA/paquete/PVE) | PASS |
| CHAP: hook ejecutado sin commit de `storage.cfg` | PASS, siguió seleccionando secreto anterior |
| conversión real CHAP legacy→generación (misma credencial) | PASS en ambos nodos |
| ambos portales bloqueados durante `pvesm free` | PASS, operación rechazada y zvol preservado |
| checksum tras `free` rechazado | PASS, SHA256 idéntico sobre 64 MiB |
| rollback inyectando paquete con `api=999` | PASS, restauró SHA anterior y storage activo |
| reinstall del paquete válido después del rollback | PASS, `dpkg` estado `ii` |
| remoción del paquete con `mptest` configurado | PASS, archivos protegidos; estado `ri` detectado y normalizado a `ii` por reinstall |
| benchmark gate 1×100 vs 2×100 Mbit/s | PASS, 2.00× read y write; cleanup 0 residual |
| actualización rolling de dependencias pendientes | PASS, 0 paquetes pendientes en ambos nodos |
| reboot frío de ambos nodos | PASS después de persistir hostname no-loopback |
| migraciones canarias durante/después del rollout | PASS, VM vuelve a `pvenest02` |
| teardown del origen final | PASS, `pvenest01` sin maps |
| destino final | PASS, `dm-0` con 2 paths `active ready running` |

El test fail-closed encontró la distinción buscada: con `10.90.1.11` y `10.90.2.11`
blackholeados, la identidad quedó **unknown**, `pvesm free` devolvió error y el zvol siguió
enumerable. Al restaurar la red, el map recuperó dos paths y el checksum fue
`70f9d4a7…a9dee5`; el cleanup posterior dejó 0 residuales.

El rollout también destapó tres problemas de host/cluster que ahora cubre el preflight:

1. `pvenest02` tenía `pve-enterprise` sin suscripción junto a `pve-no-subscription`; `apt
   update` terminaba 401. En el lab se deshabilitó enterprise y se dejó una sola familia.
2. cloud-init regeneró `/etc/hosts` de `pvenest02` como `127.0.1.1`; pmxcfs no arrancó tras
   reboot. Se fijaron ambos nombres/IP y `manage_etc_hosts: false` en los dos nodos.
3. faltaban las host keys de `pvenest02` y su symlink `/etc/ssh/ssh_known_hosts`; se tomaron
   las claves públicas por SSH autenticado, se agregaron a pmxcfs y se restauró el symlink.

Estado final: paquete 0.3.3 `ii` en ambos nodos, plugin SHA256 `8b017486…f61ec343`,
`libpve-storage-perl` 9.1.6, VM HA 8888 corriendo en `pvenest02`, quórum
y fencing armados, cero updates pendientes.

## Hardening del dataplane 0.4.1 (2026-07-14)

Canario ejecutado en `pvenest01`, dejando la VM HA 8888 activa en `pvenest02`. Cada prueba
usó un zvol scratch distinto y terminó sin maps, paths, reglas iptables ni qdiscs residuales.

| Prueba | Resultado |
|---|---|
| Perl real PVE, stubs CI, `bash -n`, ShellCheck y contrato upstream API 15/age 6 | PASS |
| build Debian + contenido/metadatos del paquete | PASS |
| alloc, CRC, snapshot, mutación, rollback con WWID nuevo, resize 3→4 GiB | PASS |
| control-plane primario black-holed | read 8 s; mutación 6 s; PASS |
| ambos portales caídos durante `free` | operación rechazada; checksum 64 MiB intacto |
| path A DROP 15 s | `fio_err=0`; max clat 13,25 s; path B siempre usable |
| path B DROP 15 s | `fio_err=0`; max clat 11,35 s; path A siempre usable |
| A+B DROP 8 s | `fio_err=0`; max clat 11,09 s; recuperación + CRC PASS |
| gate 1×100 vs 2×100 Mbit/s | write 11,41→22,82 MiB/s; read 11,41→22,81 MiB/s; 2,00× |

El primer candidato configuraba NOP-Out en `2s/2s`. Bajo carga sin rate limit el kernel
también declaró muerta la conexión no bloqueada: un falso failover doble. Se descartó ese
artefacto, se fijó `5s/5s` y el test ahora falla si cualquier muestra de un corte simple no
conserva al menos un path `active/running/ready`. Los valores se aplican a las sesiones
existentes con `iscsiadm -m session --op update`, por lo que un upgrade rolling no requiere
logout de un volumen en uso.

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
- Compatibilidad futura del plugin custom después de cambios de PVE: API window, sentinel y
  preflight reducen el riesgo, pero cada versión nueva aún requiere el gate funcional/canario.
