# zfsiscsimp — ZFS over iSCSI multipath para Proxmox VE

Plugin de storage custom que da **multipath real** a "ZFS over iSCSI" en PVE, usando el
kernel iSCSI initiator (open-iscsi) + dm-multipath en vez del libiscsi single-path del
plugin `zfs` stock. Hereda todo el manejo del lado storage (zvol por SSH + LunCmd::LIO).

Ver [docs/DESIGN.md](docs/DESIGN.md) (arquitectura y decisiones) y
[docs/RESULTS.md](docs/RESULTS.md) (pruebas y números). PoC validado el 2026-07-13;
**no es drop-in de producción** todavía (ver sección 5 de RESULTS).

## Estructura

```
src/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm   el plugin
install.sh                                    instalador (deps + plugin + multipath.conf)
conf/storage.cfg.example                      entrada de ejemplo para /etc/pve/storage.cfg
conf/multipath.conf.example                   /etc/multipath.conf recomendado
tests/01-perf.sh                              fio multipath vs single vs libiscsi
tests/02-failover-local.sh                    failover con corte por iptables
tests/03-resize-and-vm.sh                     resize online + VM real cirros
docs/DESIGN.md  docs/RESULTS.md               diseño y resultados
```

Instalación rápida: `sudo ./install.sh` en cada nodo PVE, luego seguir los pasos de abajo.

## Requisitos

**Target (server ZFS + LIO):** los portales del mismo target deben estar en **el mismo
TPG** (mismo LUN, mismo WWID → multipath los coalesce). Con targetcli:
```
/iscsi/<iqn>/tpg1/portals create <IP_portal_1> 3260
/iscsi/<iqn>/tpg1/portals create <IP_portal_2> 3260
```

**Nodo PVE (initiator):**
```
apt-get install open-iscsi multipath-tools
systemctl enable --now iscsid multipathd
```
`/etc/multipath.conf` (lo importante):
```
defaults {
    user_friendly_names no
    find_multipaths     no
    path_grouping_policy multibus
    path_selector       "round-robin 0"
    path_checker        tur
    failback            immediate
    no_path_retry       18
}
blacklist { devnode "^(ram|zram|raw|loop|fd|md|dm-|sr|scd|st|nvme)[0-9]*"; devnode "^sda[0-9]*$"; devnode "^vd[a-z]" }
blacklist_exceptions { device { vendor "LIO-ORG"; product ".*" } }
```

## Instalación

```
sudo ./install.sh
```
Instala deps (open-iscsi, multipath-tools), copia el plugin a
`/usr/share/perl5/PVE/Storage/Custom/`, pone `/etc/multipath.conf` si no existe, verifica
que el plugin carga y recarga el daemon de PVE. Manual, si preferís:
```
cp src/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
perl -e 'use PVE::Storage::Custom::ZFSiSCSIMPPlugin; print "OK\n"'
systemctl reload-or-restart pvedaemon pveproxy
```

SSH sin password del nodo al target (para leer `saveconfig.json` y manejar el LUN), un par
por portal (podés reusar la misma llave si es el mismo host):
```
mkdir -p /etc/pve/priv/zfs
ssh-keygen -t ed25519 -N '' -f /etc/pve/priv/zfs/<IP_portal_1>_id_rsa
cp /etc/pve/priv/zfs/<IP_portal_1>_id_rsa /etc/pve/priv/zfs/<IP_portal_2>_id_rsa
# instalar la .pub en root@<target>:~/.ssh/authorized_keys
```

## Configuración (`/etc/pve/storage.cfg`)

```
zfsiscsimp: mp-storage
	portal 192.168.34.11
	extraportals 192.168.34.13
	target iqn.2026-07.ar.ntc:kbuild01-tank
	pool tank
	iscsiprovider LIO
	lio_tpg tpg1
	blocksize 16k
	content images
	shared 1
	zfs-base-path /dev/zvol
	sparse 1
```
- `extraportals`: portal(es) adicional(es) del mismo target/TPG, coma-separados
  (`host` o `host:port`). Es la única propiedad nueva vs el plugin `zfs`.
- `shared 1`: **obligatorio** para migración en vivo / HA (el tipo custom no está en la
  lista `@SHARED_STORAGE` del core, así que hay que declararlo a mano).
- `zfs-base-path /dev/zvol`: en Debian los zvol están en `/dev/zvol/<pool>/...`, no `/dev/`.

## Cómo funciona (resumen)

1. `activate_storage`/`activate_volume` → `iscsiadm` login a todos los portales; dm-multipath
   arma un solo device con N paths.
2. `path()` → `/dev/disk/by-id/dm-uuid-mpath-<wwid>` (nombre estable). El WWID se deriva del
   `unit_serial` que LIO autogenera (`36001405` + 25 hex del serial), leído del
   `saveconfig.json` del target por SSH.
3. `qemu_blockdev_options` → entrega a QEMU el device multipath como `host_device` (bypassa
   el driver `iscsi`/libiscsi del plugin stock).
4. `deactivate_volume`/`free_image` → flush del map + borrado de los sd slaves + saca el WWID
   de bindings (sin cerrar la sesión compartida).
5. `volume_resize` → rescan + `multipathd resize map`.

## Limitaciones conocidas

Ver docs/RESULTS.md §5. Las principales: validado con 2 bridges internos aislados (no 2
redes físicas todavía), falta test de migración multi-nodo, y el `--rescan` es de sesión
completa (puede re-agregar maps idle de volúmenes desactivados; mitigado con `multipath -w`).

## Licencia

AGPL-3.0-or-later (deriva de `PVE::Storage::ZFSPlugin` de pve-storage, AGPL). Ver `LICENSE`.
