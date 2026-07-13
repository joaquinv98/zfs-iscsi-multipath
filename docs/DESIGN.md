# ZFS over iSCSI con multipath — PoC y plugin PVE

Fecha inicio: 2026-07-13 · Estado: en desarrollo

## Objetivo

Demostrar y dejar armado un "ZFS over iSCSI" con **multipath real** para Proxmox,
que hoy no existe porque el stock usa libiscsi en user-space (una sola sesión TCP,
sin MPIO). Ver el análisis en la conversación previa (opciones 1-4).

Enfoque elegido: **opción 2** — plugin de storage custom que reemplaza el consumo
libiscsi por **kernel initiator (open-iscsi) + dm-multipath**, heredando del plugin
`zfs` stock todo el manejo del lado storage (zvol por ssh + LunCmd::LIO).

## Topología del laboratorio (todo efímero, aislado de producción)

```
                 VLAN34 (192.168.34.0/24)
   ┌─────────────────────────┐        ┌──────────────────────────┐
   │  kbuild01 (VM 143)       │        │  pvenest01 (VM 144)       │
   │  = STORAGE ZFS + target  │        │  = Proxmox anidado        │
   │  eth0 .34.11  (portal 1) │◄──────►│  net0 .34.14 (initiator1) │
   │  ens19 .34.13 (portal 2) │◄──────►│  net1 .34.15 (initiator2) │
   │  pool "tank" (/dev/sdb)  │        │  open-iscsi + multipathd  │
   │  LIO 2 portales / 1 TPG  │        │  plugin zfsiscsimp        │
   └─────────────────────────┘        └──────────┬───────────────┘
                                                  │ crea VM de prueba
                                                  ▼  con disco sobre el
                                              storage multipath
```

- Ambas VMs en hvarres03 (nodo más vacío), cpu=host (KVM anidado en pvenest01).
- 2 portales = 2 NICs en cada punta, todo dentro de VLAN34. En una infra real
  serían 2 redes de storage físicamente separadas; acá alcanza para probar la
  lógica de multipath y el failover matando un portal.

## Componentes

### Lado storage (kbuild01) — LISTO
- Pool `tank` sobre disco de 24G (`/dev/sdb`), compression=lz4.
- Target LIO `iqn.2026-07.ar.ntc:kbuild01-tank`, TPG1 con 2 portales
  (.34.11 y .34.13), demo-mode (sin auth, generate_node_acls). Ambos portales
  en el MISMO TPG = mismo LUN, mismo WWID → multipath los coalesce.

### Plugin (ZFSiSCSIMPPlugin.pm, type `zfsiscsimp`) — en review
Hereda de `PVE::Storage::ZFSPlugin`. Overrides clave:
- `path()` → `/dev/mapper/<wwid>` en vez de `iscsi://portal/target/lun`.
- `qemu_blockdev_options()` → delega al genérico de Plugin.pm (host_device),
  no al de ZFSPlugin (libiscsi).
- `activate_storage()` → exige multipathd activo; login a todos los portales.
- `activate_volume()` → login + rescan + espera `/dev/mapper/<wwid>` (nudge
  `multipath -r` si tarda).
- `deactivate_volume()` / `free_image()` → flush del map + delete de los sd
  slaves (evita devices zombies).
- `volume_resize()` → rescan + `multipathd resize map`.
- Propiedad nueva `extraportals` (portales adicionales del mismo target/TPG).

**WWID**: LunCmd::LIO no setea unit_serial, LIO lo autogenera. El plugin lee
`storage_objects[].wwn` del `saveconfig.json` del target y arma el WWID de
multipath como `36001405` + primeros 25 hex del serial (formato NAA registered
extended, OUI de LIO 0x001405). [VERIFICAR en runtime — punto que la review marcó
como el de mayor riesgo; se contrasta contra `multipath -l` real.]

### Lado initiator (pvenest01) — LISTO
- Debian 13 + repo pve-no-subscription + `pve-manager 9.2.4` (pmxcfs standalone,
  `pvesm` operativo). open-iscsi + multipath-tools + fio + qemu-utils.
- `multipath.conf`: `user_friendly_names no`, `find_multipaths no`,
  `path_grouping_policy multibus`, `round-robin`, `no_path_retry 18`,
  blacklist_exceptions device{vendor "LIO-ORG"}.
- Plugin instalado en `/usr/share/perl5/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm`.
- Storage `mptest` en `/etc/pve/storage.cfg` (portal .11, extraportals .13,
  target, pool tank, lio_tpg tpg1, shared 1, zfs-base-path /dev/zvol).
- Llave SSH del plugin en `/etc/pve/priv/zfs/<host>_id_rsa`, pubkey en root@kbuild01.

### Verificación del WWID (el punto de mayor riesgo de la review) — CONFIRMADO
- unit_serial del backstore (LIO autogenera): `ebc07247-5467-4ec8-b9c7-c7241bfc5d8f`
- WWID real de `/lib/udev/scsi_id -g -u`: `36001405ebc0724754674ec8b9c7c7241`
- WWID que calcula el plugin (`36001405` + primeros 25 hex del serial sin guiones):
  **idéntico**. `path()` del plugin devuelve el `/dev/disk/by-id/dm-uuid-mpath-<wwid>`
  correcto. multipath coalesce los 2 portales (mismo TPG → mismo WWID) en un solo
  `dm-N` con 2 paths activos round-robin. Confirmado también por el análisis de código
  del kernel: `scsi_id` antepone "3" (NAA), OUI de LIO 0x001405, y el serial sale de
  `storage_objects[].wwn` del saveconfig.json.

### Fixes aplicados tras la review adversarial (3 lentes, 2 blockers + should-fix)
- **[blocker] `usleep`**: no lo exporta PVE::Tools → `use Time::HiRes qw(usleep)`.
  Sin esto el plugin no cargaba (confirmado en el nodo).
- **[blocker] shared**: `zfsiscsimp` no está en `@SHARED_STORAGE` del core → agregado
  `shared => { optional => 1 }` en options() + `shared 1` en storage.cfg (si no,
  migración en vivo y HA tratan el LUN como local).
- **[should-fix] WWID single-point-of-failure**: `read_saveconfig` ahora itera TODOS
  los portales (no solo el primario) para que un portal caído no bloquee activate/path.
- **[should-fix] naming /dev/mapper**: resuelvo por `/dev/disk/by-id/dm-uuid-mpath-<wwid>`
  (estable ante user_friendly_names/alias), no asumo `/dev/mapper/<wwid>`.
- **[should-fix] cache WWID sin invalidación**: `$zfsmp_forget_wwid` purga la entrada en
  teardown/free (LIO cambia el serial al recrear un backstore del mismo nombre).
- **[should-fix] extraportals**: parser host[:port]/IPv6 (`$split_portal`), no hardcodeo `:3260`.
- **[should-fix] teardown swallow**: verifico que `multipath -f` haya funcionado (5 reintentos)
  antes de borrar los sd slaves; si el map sigue en uso, free_image aborta en vez de dejar
  un map con paths colgados. Además `multipath -w <wwid>` saca el wwid de bindings para que
  un rescan no resucite un map idle.
- **[should-fix] path count / redundancia**: activate_volume avisa si quedan < N paths.
- **[bug de runtime]**: `glob` en contexto escalar no cuenta → forcé contexto de lista en
  `$zfsmp_path_count` (destapado al correr el primer activate real).

## Plan de pruebas
1. **Funcional**: crear storage, alocar zvol, ver 2 paths en `multipath -ll`,
   arrancar VM de prueba con ese disco.
2. **Multipath real**: bajar un portal (`ip link set down` / matar la IP en
   kbuild01) bajo carga fio → la VM sigue, path marcado failed, recupera al volver.
3. **Failover timing**: medir el hueco de IO al cortar un path.
4. **Performance**: fio (seq/rand, R/W) comparando single-path vs multipath
   (round-robin) vs el plugin stock libiscsi (baseline).
5. **Lifecycle**: resize online, snapshot, borrado (sin devices zombies).

## Resultados
(se completan al correr)
