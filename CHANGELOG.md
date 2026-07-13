# Changelog

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

## Pendiente (roadmap)
- Test en 2 redes de storage físicas separadas y migración en vivo multi-nodo.
- Rescan por-LUN en vez de sesión completa.
- Evaluar variante NVMe/TCP (`nvmet`) con multipath nativo (ANA).
