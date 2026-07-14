# Diseño

## Capas

```text
PVE storage API
  ├─ control: ZFS/LIO por SSH, con failover entre portales
  └─ datos: open-iscsi → SCSI paths → dm-multipath → QEMU host_device
```

El plugin hereda creación, snapshot, clone, resize y borrado del backend ZFS de PVE.
Sólo sustituye el acceso del guest y agrega coordinación de lifecycle local.

## Invariantes

1. Todos los portales configurados pertenecen al mismo IQN/TPG.
2. `shared 1`, `iscsiprovider LIO` y `lio_tpg tpgN` son obligatorios.
3. El mapa se identifica por `dm-uuid-mpath-<WWID>`, nunca por `sdX` ni alias amistoso.
4. `find_multipaths strict`: sólo un WWID admitido por activación puede formar mapa.
5. Se escanea `H:C:I:L` del LUN exacto; un LUN inactivo no se reactiva por un rescan global.
6. No se borran paths si el mapa no pudo flushearse.
7. Un path SCSI sin mapa también se elimina en teardown. Si LIO reutiliza el número de LUN,
   la activación compara el WWID y retira primero cualquier identidad stale en ese H:C:I:L.
8. Operaciones remotas mutantes no se reintentan después de comenzar; primero se elige
   un SSH sano y se ejecutan una sola vez. Lecturas sí pueden probar otro portal.

## Identidad LIO

`LunCmd::LIO` crea backstores `pool-volname`. El plugin toma `storage_objects[].wwn` y
el índice de LUN del JSON persistente. El WWID expuesto por LIO/scsi_id es
`36001405` seguido por los primeros 25 hex del serial. Se contrastó contra
`/lib/udev/scsi_id` en runtime.

La cache guarda WWID+LUN por 15 s, conserva una entrada stale sólo si el target está
temporalmente inaccesible y la invalida en free, rollback y create-base.

## Seguridad

La contraseña CHAP es una propiedad sensible de PVE y vive en pmxcfs privado, modo 0600.
El plugin configura tanto `discoverydb` como los node records. En el target se usa un ACL
por initiator, `generate_node_acls=0`, `authentication=1` y discovery CHAP.

## Timeouts del perfil probado

- NOP interval/timeout: 2/2 s.
- replacement timeout: 5 s.
- multipath polling/max polling: 1/1 s.
- fast I/O fail: 2 s.
- no-path retry: 60 checks (~60 s); dev-loss: 70 s.

Un fallo de red individual se entrega al path sano en menos de 8 s en el lab. Una pérdida
de ambos caminos se encola; no es alta disponibilidad del target.

## Compatibilidad y límites

Validado con PVE 9.2, storage API 15, multipath-tools 0.11.1, open-iscsi 2.1.11 y LIO
targetcli 2.1.53. El API se comprueba al instalar. Aún faltan pruebas de migración entre
dos nodos y hardware/switches físicos.
