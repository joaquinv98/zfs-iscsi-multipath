# zfsiscsimp — ZFS over iSCSI with real multipath for Proxmox VE 9

[![compatibility](https://github.com/joaquinv98/zfs-iscsi-multipath/actions/workflows/compat.yml/badge.svg)](https://github.com/joaquinv98/zfs-iscsi-multipath/actions/workflows/compat.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)

A third-party Proxmox VE storage plugin that gives **ZFS over iSCSI real MPIO**.
It keeps PVE's stock ZFS-over-iSCSI control plane (zvol lifecycle over SSH +
`LunCmd::LIO`) and replaces the single-path libiscsi data plane with the kernel
**open-iscsi initiator + device-mapper multipath**. QEMU gets a
`/dev/disk/by-id/dm-uuid-mpath-<wwid>` device that spans every configured portal,
so a storage NIC/switch/path failure no longer drops the guest.

The stock `zfs` type (and the common free third-party plugins) use libiscsi in
QEMU user space: one TCP session, one portal, no multipath. This plugin is a
drop-in alternative type (`zfsiscsimp`) that adds path redundancy, CHAP, and a
fail-closed lifecycle, packaged as a `.deb`.

> **Español abajo / Spanish version below.**

## What it is (and is not)

- **Is:** network-path redundancy and live-migration/HA for a ZFS+LIO target
  exported over two or more iSCSI portals to a PVE cluster.
- **Is not:** a way to survive the loss of the whole storage host. A single
  ZFS/LIO box is still a SPOF regardless of how many networks it has — tolerating
  its total loss needs a different architecture (redundant controllers/targets or
  a distributed backend). That is architectural, not a plugin limitation.

Validated on a 2-node PVE 9.2 cluster (Storage API 15): live migration both ways,
under guest IO, onto a degraded (single-path) node, with clean source teardown;
and automatic HA recovery after a hard node power-off (QDevice quorum + `softdog`
fencing). See [docs/RESULTS.md](docs/RESULTS.md).

## How it works

1. `activate_storage` logs the node's open-iscsi initiator into every portal
   (CHAP for both SendTargets discovery and session, if configured).
2. Identity (WWID + LUN) is read from the target's LIO `saveconfig.json` over the
   SSH control plane, which fails over between portals; mutations run exactly once.
3. `activate_volume` admits the WWID (`multipath -a`), scans only that LUN on each
   session, and waits for the dm map with full path redundancy.
4. `path()` / `qemu_blockdev_options()` hand QEMU the multipath block device as a
   `host_device`, bypassing the parent's libiscsi variant.
5. Teardown (deactivate/free/rollback) flushes the map and removes stale SCSI
   paths fail-closed: a destructive op aborts rather than hide an incomplete flush.

## Requirements

- PVE 9.x on each initiator, with `open-iscsi` and `multipath-tools`.
- A ZFS pool + LIO target on the storage host, exporting **two or more portals of
  the same IQN in the same TPG**.
- One SSH key per portal host in `/etc/pve/priv/zfs/<host>_id_rsa` (passwordless
  root to the target, as the stock ZFS-over-iSCSI plugin already needs).
- `shared 1` in the storage entry — the plugin refuses to activate without it.
- Recommended: an explicit LIO ACL and CHAP for login and SendTargets.
- In a cluster: one ACL/IQN per node (same CHAP). pmxcfs propagates `storage.cfg`,
  the CHAP secret and the SSH keys when a node joins.
- For **HA** (`ha-manager`): `install.sh` also restarts `pve-ha-lrm`/`pve-ha-crm`
  so they learn the custom type; without that, HA recovery fails with
  "unsupported type". A 2-node cluster needs a **QDevice** (or another third vote)
  to keep quorum and fence/recover after losing a node.

The bundled [`conf/multipath.conf.example`](conf/multipath.conf.example) uses
`find_multipaths strict` with a default-deny blacklist and a `LIO-ORG`
`blacklist_exceptions`; `activate_volume` admits each WWID explicitly, so a local
`sdX` disk can never be captured by multipath by accident.

## Install

Preferred, on each drained/maintenance PVE node:

```bash
bash packaging/build-deb.sh
sudo apt install ../pve-storage-zfsiscsimp_0.4.1_all.deb
sudo zfsiscsimp-preflight --local-only
```

Direct from the checkout (also transactional):

```bash
sudo ./install.sh
```

The installer takes a lock, validates Perl/API before reloading PVE, keeps a
bounded backup history, and restores the plugin/preflight/multipath on error or
signal. It does not install dependencies implicitly. It never overwrites an
existing `/etc/multipath.conf` — diff it against the example and validate with
`multipath -t` before reloading.

## Configure (`/etc/pve/storage.cfg`)

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

The CHAP password is a sensitive property; it is never written to `storage.cfg`:

```bash
pvesm set mp-storage --chapuser pve-initiator --password 'a-long-secret'
```

It lands in `/etc/pve/priv/storage/mp-storage.zfsiscsimp-chap`, mode `0600`. The
same user/secret must be set in the initiator's LIO ACL and in `discovery_auth`.
The secret file is generation-based: `storage.cfg` selects the committed
generation, so a failed pmxcfs commit never activates the new secret prematurely.

`blocksize` is the zvol `volblocksize`; it is fixed in the storage entry and
immutable per zvol, so choose it before writing data (OpenZFS 2.2+ defaults to
16 KiB; 4 KiB can help 4K-random guests at a space/metadata cost — measure).

## Behavior worth knowing

- Reads WWID + exact LUN from LIO's `saveconfig.json`; SSH control plane fails
  over between portals and each mutation runs exactly once.
- CHAP for discovery and login; concurrent login is idempotent.
- Scans only the requested LUN, never the whole session.
- All local `iscsiadm`/`multipath` commands are timeout-bounded (no pvestatd stall
  on a black-holed portal).
- An incomplete teardown aborts delete/rollback instead of hiding the error.
- Resize verifies the final dm map size; snapshot rollback / template conversion
  invalidate the WWID cache correctly.

## Destructive tests

Each uses a throwaway VMID/LUN, refuses collisions, and requires confirmation:

```bash
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/00-smoke-lifecycle.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/02-failover-local.sh
sudo env CONFIRM_DESTRUCTIVE=YES bash tests/10-rate-limited-performance.sh
# ... 01, 03-09 likewise; see the Spanish section for the full list and knobs.
```

Traps remove firewall rules and free only the volume the test created; tests that
close a session or reboot the target refuse to run while a live VM uses the
storage.

## Architectural limits

- A single ZFS/LIO host is a SPOF even with two networks.
- Migration/HA are certified on two nodes with a QDevice, not on larger clusters
  or physical fabrics/switches.
- Out-of-core plugin: `APIVER/APIAGE` only gates the loader. Every
  `libpve-storage-perl` upgrade needs the preflight + lifecycle + canary in
  [docs/UPGRADES.md](docs/UPGRADES.md).
- The nested-lab numbers do not size physical hardware.

License: **AGPL-3.0-or-later** (derived from `PVE::Storage::ZFSPlugin`). See
[docs/DESIGN.md](docs/DESIGN.md) and [docs/RESULTS.md](docs/RESULTS.md).

---

# zfsiscsimp — ZFS over iSCSI multipath para Proxmox VE 9 (español)

Plugin de storage de terceros que le da **MPIO real a ZFS over iSCSI**. Conserva
el control-plane del backend ZFS-over-iSCSI de PVE (ZFS por SSH + `LunCmd::LIO`) y
reemplaza el dataplane libiscsi single-path por open-iscsi + dm-multipath. A QEMU
le entrega un `/dev/disk/by-id/dm-uuid-mpath-<wwid>` que cubre todos los portales,
así una falla de NIC/switch/camino de storage no tira el guest.

Estado: **production candidate para redundancia de red + migración/HA**, validado
en un cluster PVE 9.2 de 2 nodos (API 15): migración en vivo ida y vuelta, bajo IO
del guest, a un nodo con un path degradado, con teardown limpio del origen; y
recovery HA automático ante muerte de nodo (QDevice + fencing softdog). Ver
[docs/RESULTS.md](docs/RESULTS.md). No convierte un único servidor ZFS/LIO en
storage HA: tolerar la caída completa del target necesita otra arquitectura
(controladoras/targets redundantes o un backend distribuido) — es arquitectónico,
no del plugin.

Documentación: [diseño](docs/DESIGN.md), [resultados reproducibles](docs/RESULTS.md)
y [runbook de upgrades](docs/UPGRADES.md).

## Requisitos

- PVE 9.x en cada initiator, con `open-iscsi` y `multipath-tools`.
- LIO y ZFS en el target, con al menos dos portales del mismo IQN y TPG.
- Una llave SSH por host/portal en `/etc/pve/priv/zfs/<host>_id_rsa`.
- `shared 1`; el plugin lo rechaza si falta.
- Recomendado: ACL explícito y CHAP para login y SendTargets.
- En cluster: un ACL/IQN por nodo (mismo CHAP). pmxcfs propaga `storage.cfg`, el
  secreto CHAP y las llaves SSH al unir un nodo.
- Para **HA** (`ha-manager`): `install.sh` reinicia también `pve-ha-lrm`/`pve-ha-crm`
  para que reconozcan el plugin; sin eso la recuperación HA falla con "unsupported
  type". Un cluster de 2 nodos necesita un **QDevice** (u otro 3er voto) para
  conservar quórum y poder fencear/recuperar al perder un nodo.

## Instalación

Preferido, en cada nodo PVE drenado/en mantenimiento:

```bash
bash packaging/build-deb.sh
sudo apt install ../pve-storage-zfsiscsimp_0.4.1_all.deb
sudo zfsiscsimp-preflight --local-only
```

Instalación directa desde el checkout (también transaccional):

```bash
sudo ./install.sh
```

El instalador usa un lock, valida Perl/API antes de recargar PVE, conserva un
historial acotado y restaura plugin, preflight y multipath ante error o señal. No
instala dependencias implícitamente. Si ya existe `/etc/multipath.conf`, no lo
reemplaza: compararlo con `conf/multipath.conf.example` y validar con `multipath -t`
antes del reload.

La política incluida usa `find_multipaths strict` y un blacklist default-deny con
excepción por vendor `LIO-ORG`; `activate_volume` admite el WWID explícitamente.
Esto evita que un disco local cambie de nombre y termine capturado por multipath.

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
usuario/secreto debe configurarse en el ACL del initiator y en `discovery_auth` de
LIO. Los node records ya conectados deben reloguearse después de cambiar timers o
CHAP. Desde 0.3.0 el archivo contiene generaciones: `storage.cfg` selecciona la
credencial committed y una falla posterior del commit no activa prematuramente el
secreto nuevo.

OpenZFS 2.2+ usa 16 KiB como default equilibrado. Para guests 4K random puede
convenir `blocksize 4k`, con mayor metadata/menor eficiencia de espacio; medir en
el pool real. PVE trata este campo como fijo y ZFS no permite cambiar el
`volblocksize` de un zvol existente: elegirlo antes de cargar datos.

## Comportamiento importante

- Lee identidad, WWID y LUN exacto desde el `saveconfig.json` de LIO.
- El control-plane SSH conmuta entre portales; una mutación se ejecuta una sola vez.
- Discovery y login soportan CHAP; login concurrente es idempotente.
- Escanea únicamente el LUN solicitado, no toda la sesión.
- Todo comando local `iscsiadm`/`multipath` tiene timeout (sin cuelgue de pvestatd
  ante un portal black-holed).
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

`TEST_MODES=multipath` o `TEST_MODES=single` permiten repetir sólo una mitad. La
fase single bloquea un portal y espera exactamente un path usable, por lo que
`pvestatd` no puede sesgar el resultado relogueando la sesión durante la medición.

`10-rate-limited-performance.sh` es el gate corto: compara el mismo dm-map con uno
y dos paths de 100 Mbit/s y falla si lectura o escritura no escalan al menos 1,50×.

Los traps quitan reglas de firewall y liberan sólo el volumen que el test creó. Los
tests que cierran una sesión o reinician el target se niegan a correr si una VM
activa usa el storage.

## Límites que siguen siendo arquitectónicos

- Un solo host ZFS/LIO es un SPOF aunque tenga dos redes.
- Migración y recovery HA están certificados en dos nodos con QDevice, no en
  clusters mayores ni fabrics/switches físicos.
- Es un plugin fuera del core; `APIVER/APIAGE` sólo valida el loader. Cada upgrade
  de `libpve-storage-perl` requiere preflight, lifecycle y canario según
  `docs/UPGRADES.md`.
- Los números del lab anidado no dimensionan hardware físico.

Licencia: AGPL-3.0-or-later; deriva de `PVE::Storage::ZFSPlugin`.
