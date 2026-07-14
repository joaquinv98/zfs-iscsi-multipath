# Upgrades de Proxmox VE

`APIVER/APIAGE` es un primer filtro, no una certificación. `zfsiscsimp` hereda y
sobreescribe métodos de `PVE::Storage::ZFSPlugin`; una versión puede cargar correctamente
y aun cambiar firmas o comportamiento interno. Por eso cada combinación de
`libpve-storage-perl` y plugin debe atravesar un gate funcional antes de producción.

## Modelo de entrega

1. Construir un `.deb` versionado, no copiar archivos distintos en cada nodo:

   ```bash
   bash packaging/build-deb.sh
   ```

2. Publicarlo primero en un snapshot de repositorio de laboratorio.
3. Validarlo contra la versión enterprise instalada y contra la candidata de `pvetest`.
4. Promover el mismo snapshot inmutable al repositorio de producción.
5. Conservar el `.deb` anterior y el snapshot de paquetes PVE para recuperación.

No se recomienda mantener un `apt-mark hold` permanente sobre paquetes centrales de PVE:
puede impedir actualizaciones de seguridad o producir un stack parcialmente actualizado.
La barrera debe estar en la promoción del repositorio y en el preflight.

## Estado que se debe respaldar

Cluster-wide mediante pmxcfs:

- `/etc/pve/storage.cfg`;
- `/etc/pve/priv/storage/*.zfsiscsimp-chap`;
- `/etc/pve/priv/zfs/*_id_rsa`.

Local a cada nodo:

- paquete y SHA del plugin;
- `/etc/multipath.conf` y `/etc/multipath/`;
- `/etc/iscsi/initiatorname.iscsi` y `/etc/iscsi/nodes/`;
- inventario `pveversion -v` y `dpkg-query -W libpve-storage-perl`;
- configuración de red de las fabrics iSCSI.

pmxcfs no distribuye el plugin, paquetes, configuración multipath ni identidad iSCSI.

## Gate previo

En cada nodo, antes de tocar paquetes:

```bash
zfsiscsimp-preflight --local-only --storage mp-storage
zfsiscsimp-preflight --cluster --storage mp-storage
```

El gate comprueba loader/API, métodos upstream usados, versión y SHA, paquete PVE,
servicios, configuración multipath, acceso al storage y binding CHAP. El modo cluster
exige el mismo plugin y la misma versión de `libpve-storage-perl` en todos los nodos.

Para un salto mayor también se debe ejecutar el checker oficial correspondiente, por
ejemplo `pve8to9 --full`, corregir todos sus errores y verificar backups restaurables,
quórum y acceso de consola/IPMI.

## Rollout canario

1. Poner un nodo en mantenimiento y migrar todas sus cargas.
2. Actualizar únicamente ese nodo y reiniciarlo si el stack PVE lo requiere.
3. Instalar exactamente el `.deb` candidato.
4. Ejecutar el gate local. Durante el estado mixto se puede inspeccionar el cluster con:

   ```bash
   zfsiscsimp-preflight --cluster --allow-pve-skew --storage mp-storage
   ```

   La opción sólo tolera skew temporal de `libpve-storage-perl`; una diferencia de
   versión/API/SHA del plugin sigue siendo error.

   Durante un upgrade 0.2.x→0.3.x no rotar CHAP ni modificar el storage hasta que el mismo
   plugin esté instalado en todos los nodos: 0.2.x no entiende la generación nueva. El
   archivo legacy sigue siendo compatible durante el rollout; convertirlo recién después.

5. Ejecutar el gate funcional:

   ```bash
   cd /ruta/al/repo
   CONFIRM_DESTRUCTIVE=YES RUN_CLUSTER_GATE=0 RUN_DESTRUCTIVE=1 \
       tests/09-upgrade-gate.sh
   ```

6. Migrar una VM canaria desde un nodo viejo al nuevo, primero sin IO y luego bajo IO.
7. En un salto mayor no planificar el rollback migrando de la versión nueva a la vieja;
   esa dirección generalmente no está soportada. Mantener la mayoría de las cargas en el
   nodo viejo hasta aceptar el canario y luego avanzar en una sola dirección.
8. Repetir nodo por nodo. Al terminar, ejecutar `zfsiscsimp-preflight --cluster` sin
   tolerancia de skew y repetir migración/HA.

## Criterios de aceptación

- `PREFLIGHT_OK` local y cluster-wide;
- alloc/activate/IO CRC/deactivate/free sin residuales;
- pérdida de un path sin error de IO;
- pérdida total del control-plane rechaza `free` sin destruir el zvol;
- resize online y snapshot rollback;
- migración live normal, bajo IO y hacia un nodo con un path degradado;
- recuperación HA por fencing;
- misma versión y SHA del plugin en todos los nodos.
- hostname de cada nodo resolviendo a su IP no-loopback aun después de reboot;
- `/etc/ssh/ssh_known_hosts` cluster-wide legible y una sola familia de repos PVE activa.

## Rollback

Si falla el canario, no actualizar los demás nodos. Reinstalar el `.deb` anterior,
recargar los daemons PVE y ejecutar el preflight local. `install.sh` y los maintainer
scripts del paquete restauran los archivos anteriores si su validación falla, pero eso no
equivale a revertir un upgrade mayor completo de Debian/PVE.

No hacer downgrade improvisado de paquetes PVE. Para un salto mayor fallido, recuperar el
nodo desde backup/snapshot de sistema o reinstalarlo con el snapshot anterior del
repositorio, manteniendo las VMs en los nodos todavía no actualizados.

El paquete rechaza `remove` mientras exista una entrada `zfsiscsimp` en `storage.cfg`. Para
retirarlo deliberadamente, migrar/liberar primero sus volúmenes, eliminar el storage del
cluster y recién entonces remover el paquete en cada nodo.

Una remoción rechazada protege los archivos, pero `dpkg` puede conservar la selección
`remove` (`ri`: deseado remove, todavía installed). El preflight la trata como error. Se
normaliza reinstalando el `.deb` aprobado y repitiendo el gate hasta obtener estado `ii`.

## Rotación y limpieza CHAP

El password se guarda en un registro versionado. `storage.cfg` apunta a una generación:
si falla su commit, la configuración anterior sigue resolviendo el secreto anterior. Los
hooks nunca borran un secreto antes del commit. Luego de eliminar un storage o completar
una rotación se pueden retirar huérfanos comprobados con:

```bash
zfsiscsimp-preflight --cleanup-secrets
```

La limpieza sólo elimina archivos cuyo storage ID ya no existe; nunca adivina el resultado
de una operación fallida.
