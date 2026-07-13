#!/bin/bash
# Installer for the zfsiscsimp PVE storage plugin. Run as root on each PVE node.
#
#   ./install.sh
#
# Idempotent: safe to re-run to upgrade the plugin.
set -euo pipefail

PLUGIN_SRC="$(dirname "$0")/src/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm"
PLUGIN_DST="/usr/share/perl5/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm"
MP_SRC="$(dirname "$0")/conf/multipath.conf.example"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "==> dependencias (open-iscsi, multipath-tools)"
if ! dpkg -s open-iscsi multipath-tools >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y open-iscsi multipath-tools
fi
systemctl enable --now iscsid multipathd

echo "==> instalar plugin en $PLUGIN_DST"
install -D -m 0644 "$PLUGIN_SRC" "$PLUGIN_DST"
perl -e 'use PVE::Storage::Custom::ZFSiSCSIMPPlugin;' \
    && echo "    plugin carga OK" \
    || { echo "    ERROR: el plugin no carga"; exit 1; }

if [ ! -f /etc/multipath.conf ]; then
    echo "==> instalar /etc/multipath.conf desde el ejemplo"
    install -m 0644 "$MP_SRC" /etc/multipath.conf
    systemctl restart multipathd
else
    echo "==> /etc/multipath.conf ya existe - reviselo contra conf/multipath.conf.example"
fi

echo "==> recargar el storage daemon de PVE para que descubra el plugin"
systemctl reload-or-restart pvedaemon pveproxy 2>/dev/null || \
    echo "    (pvedaemon/pveproxy no presentes; en un nodo PVE real correrian)"

cat <<'NEXT'

Plugin instalado. Pasos que quedan (ver README.md):
  1. SSH sin password a cada portal del target, llaves en /etc/pve/priv/zfs/<host>_id_rsa
     (una por portal; podes reusar la misma si es el mismo host fisico).
  2. Portales del target en el MISMO TPG.
  3. Agregar el storage a /etc/pve/storage.cfg (ver conf/storage.cfg.example).
NEXT
