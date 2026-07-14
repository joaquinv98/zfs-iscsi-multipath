# zfsiscsimp — ZFS over iSCSI multipath para Proxmox VE 9

Plugin custom que conserva el control-plane del backend ZFS-over-iSCSI de PVE
(ZFS por SSH + `LunCmd::LIO`) y reemplaza el dataplane libiscsi single-path por
open-iscsi + dm-multipath.

Estado: **production candidate para redundancia de red + migración/HA**, validado en un
cluster PVE 9.2 de 2 nodos (API 15): migración en vivo ida y vuelta, bajo IO del guest, y
a un nodo con un path degradado, con teardown limpio del origen (ver docs/RESULTS.md).
No convierte un único servidor ZFS/LIO en storage HA: para tolerar la caída completa del
target hace falta otra arquitectura (controladoras/targets redundantes o un backend
distribuido) — eso es arquitectónico, no del plugin.

Documentación: [diseño](docs/DESIGN.md), [resultados reproducibles](docs/RESULTS.md) y
[runbook de upgrades](docs/UPGRADES.md).

## Requisitos

- PVE 9.x en cada initiator, con `open-iscsi` y `multipath-tools`.
- LIO y ZFS en el target.
- Al menos dos portales del mismo IQN y el mismo TPG.
- Una llave SSH por host/portal en `/etc/pve/priv/zfs/<host>_id_rsa`.
- `shared 1`; el plugin lo rechaza si falta.
- Recomendado: ACL explícito y CHAP para login y SendTargets.
- En cluster: un ACL/IQN por nodo (mismo CHAP). pmxcfs propaga `storage.cfg`, el secreto
  CHAP y las llaves SSH al unir un nodo.
- Para **HA** (`ha-manager`): `install.sh` reinicia también `pve-ha-lrm`/`pve-ha-crm` para
  que reconozcan el plugin; sin eso la recuperación HA falla con "unsupported type". Un
  cluster de 2 nodos necesita un **QDevice** (u otro 3er voto) para conservar quórum y poder
  fencear/recuperar al perder un nodo.

## Instalación

Preferido, en cada nodo PVE drenado/en mantenimiento:

```bash
bash packaging/build-deb.sh
sudo apt install ../pve-storage-zfsiscsimp_0.4.0_all.deb
sudo zfsiscsimp-preflight --local-only
```

Instalación directa desde el checkout (también transaccional):

```bash
sudo ./install.sh
```

El instalador usa un lock, valida Perl/API antes de recargar PVE, conserva un historial
acotado y restaura plugin, preflight y multipath ante error o señal. No instala dependencias
implícitamente. Si ya existe
`/etc/multipath.conf`, no lo reemplaza: compararlo con
`conf/multipath.conf.example` y validar con `multipath -t` antes del reload.

La política incluida usa `find_multipaths strict` y un blacklist default-deny con
excepción por vendor `LIO-ORG`; `activate_volume` admite el WWID explícitamente. Esto
evita que un disco local cambie de nombre y termine capturado por multipath.

## Configuración PVE

```text
zfsiscsimp: mp-storage
	portal 10.90.1.11
	extraportals 10.90.2.11
	target iqn.2026-07.ar.ntc:kbuild01-tank
	pool tank
	iscsiprovider LIO
	lio_tpg tpg1
	blocksize 16k
	content images
	shared 1
	sparse 1
	zfs-base-path /dev/zvol
	chapuser pve-initiator
```

La contraseña CHAP se carga como propiedad sensible, no se escribe en `storage.cfg`:

```bash
pvesm set mp-storage --chapuser pve-initiator --password 'secreto-largo'
```

Queda en `/etc/pve/priv/storage/mp-storage.zfsiscsimp-chap`, modo `0600`. El mismo
usuario/secreto debe configurarse en el ACL del initiator y en `discovery_auth` de LIO.
Los node records ya conectados deben reloguearse después de cambiar timers o CHAP.
Desde 0.3.0 el archivo contiene generaciones: `storage.cfg` selecciona la credencial
committed y una falla posterior del commit no activa prematuramente el secreto nuevo.

OpenZFS 2.2+ usa 16 KiB como default equilibrado. Para guests 4K random puede convenir
`blocksize 4k`, con mayor metadata/menor eficiencia de espacio; medir en el pool real.
PVE trata este campo como fijo en la entrada de storage y ZFS no permite cambiar el
`volblocksize` de un zvol existente: elegirlo antes de cargar datos.

## Comportamiento importante

- Lee identidad, WWID y LUN exacto desde el `saveconfig.json` de LIO.
- El control-plane SSH conmuta entre portales; una mutación se ejecuta una sola vez.
- Discovery y login soportan CHAP; login concurrente es idempotente.
- Escanea únicamente el LUN solicitado, no toda la sesión.
- Entrega a QEMU `/dev/disk/by-id/dm-uuid-mpath-<WWID>` como `host_device`.
- Un teardown incompleto aborta delete/rollback en vez de ocultar el error.
- Resize verifica el tamaño final del mapa dm.
- Snapshot rollback y template conversion invalidan WWID/cache correctamente.

## Tests destructivos

Todos usan un VMID/LUN descartable, rechazan colisiones y requieren confirmación:

```bash
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/00-smoke-lifecycle.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/01-perf.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/02-failover-local.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/03-resize-and-vm.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/04-control-plane.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/05-security.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/06-target-reboot.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/07-identity-fail-closed.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/08-chap-transaction.sh
sudo env CONFIRM_DESTRUCTIVE=YES RUN_DESTRUCTIVE=1 bash tests/09-upgrade-gate.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/10-rate-limited-performance.sh
```

El benchmark puede limitar cada fabric virtual sin tocar management. Aplica `tc` en
initiator+target, guarda configuración/contadores y restaura `fq_codel` al salir:

```bash
sudo env CONFIRM_DESTRUCTIVE=YES RATE_LIMIT_MBIT=100 bash tests/01-perf.sh
```

`TEST_MODES=multipath` o `TEST_MODES=single` permiten repetir sólo una mitad. La fase
single bloquea un portal y espera exactamente un path usable, por lo que `pvestatd` no
puede sesgar el resultado relogueando la sesión durante la medición.

`10-rate-limited-performance.sh` es el gate corto: compara el mismo dm-map con uno y dos
paths de 100 Mbit/s y falla si lectura o escritura no escalan al menos 1,50×.

Los traps quitan reglas de firewall y liberan sólo el volumen que el test creó. Los tests
que cierran una sesión o reinician el target se niegan a correr si una VM activa usa el
storage.

## Límites que siguen siendo arquitectónicos

- Un solo host ZFS/LIO es un SPOF aunque tenga dos redes.
- Migración y recovery HA están certificados en dos nodos con QDevice, no en clusters
  mayores ni fabrics/switches físicos.
- Es un plugin fuera del core; `APIVER/APIAGE` sólo valida el loader. Cada upgrade de
  `libpve-storage-perl` requiere preflight, lifecycle y canario según `docs/UPGRADES.md`.
- Los números del lab anidado no dimensionan hardware físico.

Licencia: AGPL-3.0-or-later; deriva de `PVE::Storage::ZFSPlugin`.
