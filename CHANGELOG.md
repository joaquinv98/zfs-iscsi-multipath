# Changelog

## 0.2.2 — 2026-07-14

HA real certificada (recuperación automática ante muerte de nodo) + fix de deployment.

- **HA validada**: cluster de 2 nodos con QDevice (`corosync-qnetd`), VM como recurso
  `ha-manager`, watchdog `softdog`. Power-off duro del nodo activo → fence (~144 s) →
  la VM revive sola en el nodo superviviente con su disco multipath y 2 paths; guest
  cold-boot crash-consistent. Ver docs/RESULTS.md.
- **Fix production-critical (`install.sh`)**: los daemons HA `pve-ha-lrm` y `pve-ha-crm`
  no se reiniciaban al instalar el plugin, así que cacheaban el registro de `PVE::Storage`
  sin el tipo custom. Resultado: la recuperación HA fallaba con
  `unsupported type 'zfsiscsimp' ... storage does not exist` aunque la migración manual
  (vía pvedaemon) funcionara. El instalador ahora reinicia también los daemons HA presentes.
  El plugin en sí no cambió (solo el procedimiento de instalación/recarga de daemons).
- Nota operativa documentada: un cluster de 2 nodos necesita un QDevice (u otro 3er voto)
  para que el fencing pueda recuperar tras perder un nodo; sin él no hay quórum.

## 0.2.1 — 2026-07-14

Validado en cluster PVE real de 2 nodos con migración en vivo; fixes de la review 0.2.0.

- **Migración en vivo certificada** (shared storage): ida y vuelta con downtime 2 ms, bajo IO
  del guest 15 ms, a nodo con 1 path degradado, con teardown del origen a 0 residual.
- Fix (destapado por la migración): la ventana de flush de `$zfsmp_teardown` (5×300 ms) era
  muy corta para la carrera del cleanup de migración (QEMU recién salido + udev sostienen el
  map). Ampliada a backoff ~15 s. `deactivate_volume`/`free_image` ya no fallan por esa carrera.
- Fix (review #5): `read_saveconfig` corría el `ssh cat` sin `timeout`; un target trabado
  colgaba el worker indefinidamente (colgó un `activate_storage` en el 2º nodo). `timeout => 10`.
- Fix (review #1): `on_update_hook_full` borraba el secreto CHAP antes de validar la
  dependencia `chapuser`→password; ahora valida el resultado antes de mutar el archivo (que es
  cluster-wide vía pmxcfs y dejaba el storage inactivo en todos los nodos).
- Fix (review #2): `$zfsmp_teardown` confundía "volumen no identificable" (backstore borrado)
  con "map en uso"; un volumen huérfano no se podía liberar nunca. Ahora distingue y `free_image`
  procede a destruir el zvol.
- Fix (review #3): `install.sh` fijaba `api()==APIVER` exacto; ahora acepta la ventana
  `[APIVER-APIAGE, APIVER]` que usa PVE, para no bloquear upgrades del plugin tras un bump de API.
- Cluster: se documentó que cada nodo necesita su propio IQN + ACL en el target (mismo CHAP);
  pmxcfs propaga `storage.cfg` + secreto CHAP + llaves SSH automáticamente al unir un nodo.

## 0.2.0 — 2026-07-14

- Política multipath default-deny, `find_multipaths strict`, cola finita y timers medidos.
- CHAP para SendTargets y login, secreto fuera de `storage.cfg` y ACL LIO explícito.
- Failover SSH del control-plane sin replay de mutaciones.
- Escaneo por LUN, identidad WWID+LUN, teardown estricto y resize verificado. El teardown
  elimina también paths SCSI sin mapa dm y la activación sanea un H:C:I:L stale antes de
  reutilizar su número de LUN.
- Hooks seguros para rollback/template y validación obligatoria de LIO/shared/TPG.
- Login concurrente idempotente y parser portal/IPv6 corregido.
- Instalador atómico con validación API y rollback automático.
- Suite destructiva aislada: lifecycle, performance, failover, VM, seguridad,
  control-plane y reboot completo del target.
- Todos los scripts pasan `bash -n` y `shellcheck` sin hallazgos.
- El lab queda con política 16 KiB para zvols nuevos; alloc/activate/free confirmó el
  volblocksize y que no quedan paths crudos. El zvol existente de 4 KiB se preservó.
- Benchmark opcional con `tc` por fabric (`RATE_LIMIT_MBIT`), restauración verificada,
  selección `TEST_MODES` y single-path protegido contra relogin de `pvestatd`. Con cada
  path a 100 Mbit/s se midió 1.99–2.00× de throughput multipath/single-path.
- Validación: PVE/kernel/storage reboots, fio+CRC, kernel GET LBA STATUS/libiscsi.

## 0.1.0 — 2026-07-13

Primera versión funcional (PoC validado). Ver `docs/RESULTS.md`.

- Plugin `zfsiscsimp` (`type = zfsiscsimp`) que hereda de `PVE::Storage::ZFSPlugin` y
  reemplaza el consumo libiscsi single-path por kernel initiator (open-iscsi) + dm-multipath.
- Propiedad nueva `extraportals` (portales adicionales del mismo target/TPG).
- `path()` / `qemu_blockdev_options()` entregan a QEMU el device multipath (`host_device`
  vía `/dev/disk/by-id/dm-uuid-mpath-<wwid>`).
- WWID derivado del `unit_serial` de LIO leído del `saveconfig.json` del target por SSH
  (`36001405` + 25 hex del serial); verificado idéntico al de `scsi_id`.
- `activate_storage`/`activate_volume` hacen login a todos los portales y esperan el map;
  `deactivate_volume`/`free_image` hacen flush del map + limpieza de sd slaves.
- `volume_resize` propaga el tamaño (rescan + `multipathd resize map`).
- Validado: 2 paths round-robin, failover sin pérdida de IO (redes aisladas, corte de link
  real), resize online, VM real booteando desde el disco multipath con IO balanceado.

### Correcciones de la review adversarial (pre-release)
- `usleep` desde `Time::HiRes` (PVE::Tools no lo exporta; el plugin no cargaba).
- `shared` agregado a `options()` (el tipo custom no está en `@SHARED_STORAGE` del core;
  sin esto se rompe migración en vivo / HA).
- `read_saveconfig` itera todos los portales (un portal caído no bloquea activate/path).
- Resolución del device por `/dev/disk/by-id/dm-uuid-mpath-<wwid>` (estable ante
  `user_friendly_names`/alias).
- Invalidación de la cache de WWID en teardown/free.
- Parser de `extraportals` host[:port]/IPv6 (no hardcodea `:3260`).
- Teardown verifica que `multipath -f` funcionó antes de borrar los sd slaves; saca el WWID
  de bindings para que un rescan no resucite maps idle.
- `$zfsmp_path_count` cuenta en contexto de lista (bug de runtime: `glob` escalar).

## Pendiente histórico de 0.1 (scan por LUN resuelto en 0.2)
- Test en 2 redes de storage físicas separadas y migración en vivo multi-nodo.
- Rescan por-LUN en vez de sesión completa.
- Evaluar variante NVMe/TCP (`nvmet`) con multipath nativo (ANA).
