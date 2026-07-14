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
PLUGIN_TMP=
PLUGIN_BACKUP=

cleanup() {
    if [ -n "$PLUGIN_TMP" ]; then
        rm -f "$PLUGIN_TMP"
    fi
    return 0
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

echo "==> dependencias (open-iscsi, multipath-tools)"
if ! dpkg -s open-iscsi multipath-tools >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y open-iscsi multipath-tools
fi
systemctl enable --now iscsid multipathd

echo "==> validar plugin antes de reemplazar la version instalada"
perl -c "$PLUGIN_SRC"

echo "==> instalar plugin atomically en $PLUGIN_DST"
install -d -m 0755 "$(dirname "$PLUGIN_DST")"
PLUGIN_TMP="${PLUGIN_DST}.new.$$"
install -m 0644 "$PLUGIN_SRC" "$PLUGIN_TMP"
if [ -f "$PLUGIN_DST" ]; then
    PLUGIN_BACKUP="${PLUGIN_DST}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$PLUGIN_DST" "$PLUGIN_BACKUP"
fi
mv -f "$PLUGIN_TMP" "$PLUGIN_DST"
PLUGIN_TMP=

rollback_plugin() {
    if [ -n "$PLUGIN_BACKUP" ]; then
        cp -a "$PLUGIN_BACKUP" "$PLUGIN_DST"
    else
        rm -f "$PLUGIN_DST"
    fi
}

# Loading PVE::Storage exercises the custom-plugin loader, API compatibility,
# registration and schema initialization; a plain 'use plugin' does not.
perl -MPVE::Storage -e '
    my $plugin = PVE::Storage::Plugin->lookup("zfsiscsimp");
    die "zfsiscsimp did not register\n" if !$plugin;
    # Accept the same compatibility window PVE itself uses: [APIVER-APIAGE, APIVER].
    # A strict equality would refuse to install plugin fixes after a routine
    # pve-storage APIVER bump even though PVE would still load the plugin.
    my $api = $plugin->api();
    my ($ver, $age) = (PVE::Storage::APIVER, PVE::Storage::APIAGE);
    die "API incompatible: plugin=$api PVE supports [" . ($ver - $age) . "..$ver]\n"
        if $api > $ver || $api < $ver - $age;
    print "    plugin registrado, api=$api (PVE $ver, age $age)\n";
' || {
    echo "    ERROR: PVE rechazo el plugin; restaurando la version anterior"
    rollback_plugin
    exit 1
}

if [ ! -f /etc/multipath.conf ]; then
    echo "==> instalar /etc/multipath.conf desde el ejemplo"
    install -m 0644 "$MP_SRC" /etc/multipath.conf
    multipath -t >/dev/null || {
        rm -f /etc/multipath.conf
        echo "    ERROR: multipath rechazo la configuracion; archivo removido"
        exit 1
    }
    systemctl reload-or-restart multipathd
else
    echo "==> /etc/multipath.conf ya existe - reviselo contra conf/multipath.conf.example"
fi

echo "==> recargar todos los daemons persistentes que cargan PVE::Storage"
for service in pvedaemon pveproxy pvestatd pvescheduler; do
    systemctl reload-or-restart "$service"
    systemctl is-active --quiet "$service" || {
        echo "    ERROR: $service no quedo activo; restaurando el plugin"
        rollback_plugin
        for rollback_service in pvedaemon pveproxy pvestatd pvescheduler; do
            systemctl reload-or-restart "$rollback_service" || true
        done
        exit 1
    }
done

cat <<'NEXT'

Plugin instalado. Pasos que quedan (ver README.md):
  1. SSH sin password a cada portal del target, llaves en /etc/pve/priv/zfs/<host>_id_rsa
     (una por portal; podes reusar la misma si es el mismo host fisico).
  2. Portales del target en el MISMO TPG.
  3. Agregar el storage a /etc/pve/storage.cfg (ver conf/storage.cfg.example).
NEXT
