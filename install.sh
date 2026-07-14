#!/bin/bash
# Transactional installer for the zfsiscsimp PVE storage plugin.
# Run on a drained/maintenance PVE node; package installation is preferred.

set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_SRC="$BASE_DIR/src/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm"
PLUGIN_DST=/usr/share/perl5/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm
PREFLIGHT_SRC="$BASE_DIR/bin/zfsiscsimp-preflight"
PREFLIGHT_DST=/usr/sbin/zfsiscsimp-preflight
MP_SRC="$BASE_DIR/conf/multipath.conf.example"
LOCK_FILE=/run/lock/zfsiscsimp-install.lock

PLUGIN_TMP=
PLUGIN_BACKUP=
PLUGIN_HAD_ORIGINAL=0
PLUGIN_REPLACED=0
PREFLIGHT_TMP=
PREFLIGHT_BACKUP=
PREFLIGHT_HAD_ORIGINAL=0
PREFLIGHT_REPLACED=0
MP_INSTALLED=0
COMMITTED=0
ROLLING_BACK=0
STORAGE_DAEMONS=(pvedaemon pveproxy pvestatd pvescheduler)

cleanup_temps() {
    [ -z "$PLUGIN_TMP" ] || rm -f -- "$PLUGIN_TMP"
    [ -z "$PREFLIGHT_TMP" ] || rm -f -- "$PREFLIGHT_TMP"
}

restore_file() {
    local destination=$1 backup=$2 had_original=$3
    if [ "$had_original" -eq 1 ]; then
        cp -a -- "$backup" "$destination"
    else
        rm -f -- "$destination"
    fi
}

reload_storage_daemons() {
    local service
    for service in "${STORAGE_DAEMONS[@]}"; do
        systemctl reload-or-restart "$service" || true
    done
}

rollback_install() {
    [ "$ROLLING_BACK" -eq 0 ] || return 0
    ROLLING_BACK=1
    echo "==> ERROR: revirtiendo instalacion incompleta" >&2
    if [ "$PLUGIN_REPLACED" -eq 1 ]; then
        restore_file "$PLUGIN_DST" "$PLUGIN_BACKUP" "$PLUGIN_HAD_ORIGINAL"
    fi
    if [ "$PREFLIGHT_REPLACED" -eq 1 ]; then
        restore_file "$PREFLIGHT_DST" "$PREFLIGHT_BACKUP" "$PREFLIGHT_HAD_ORIGINAL"
    fi
    if [ "$MP_INSTALLED" -eq 1 ]; then
        rm -f -- /etc/multipath.conf
        systemctl reload-or-restart multipathd || true
    fi
    reload_storage_daemons
}

on_exit() {
    local rc=$?
    trap - EXIT
    set +e
    cleanup_temps
    if [ "$rc" -ne 0 ] && [ "$COMMITTED" -eq 0 ]; then
        rollback_install
    fi
    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT TERM HUP

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock is required (package util-linux)" >&2; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "another zfsiscsimp install is already running" >&2; exit 1; }

for ha in pve-ha-lrm pve-ha-crm; do
    systemctl cat "${ha}.service" >/dev/null 2>&1 && STORAGE_DAEMONS+=("$ha")
done

echo "==> validar fuentes antes de modificar el nodo"
perl -c "$PLUGIN_SRC"
bash -n "$PREFLIGHT_SRC"

missing=()
for package in libpve-storage-perl open-iscsi multipath-tools; do
    dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii ' ||
        missing+=("$package")
done
if [ "${#missing[@]}" -ne 0 ]; then
    printf 'faltan dependencias: %s\n' "${missing[*]}" >&2
    echo "instalelas explicitamente con apt antes de ejecutar este instalador" >&2
    exit 1
fi

systemctl enable --now iscsid multipathd

timestamp=$(date +%Y%m%d%H%M%S)

echo "==> instalar plugin atomicamente en $PLUGIN_DST"
install -d -m 0755 "$(dirname "$PLUGIN_DST")"
PLUGIN_TMP="${PLUGIN_DST}.new.$$"
install -m 0644 "$PLUGIN_SRC" "$PLUGIN_TMP"
if [ -f "$PLUGIN_DST" ]; then
    PLUGIN_HAD_ORIGINAL=1
    PLUGIN_BACKUP="${PLUGIN_DST}.bak.${timestamp}"
    cp -a -- "$PLUGIN_DST" "$PLUGIN_BACKUP"
fi
mv -f -- "$PLUGIN_TMP" "$PLUGIN_DST"
PLUGIN_TMP=
PLUGIN_REPLACED=1

echo "==> instalar preflight atomicamente en $PREFLIGHT_DST"
PREFLIGHT_TMP="${PREFLIGHT_DST}.new.$$"
install -m 0755 "$PREFLIGHT_SRC" "$PREFLIGHT_TMP"
if [ -f "$PREFLIGHT_DST" ]; then
    PREFLIGHT_HAD_ORIGINAL=1
    PREFLIGHT_BACKUP="${PREFLIGHT_DST}.bak.${timestamp}"
    cp -a -- "$PREFLIGHT_DST" "$PREFLIGHT_BACKUP"
fi
mv -f -- "$PREFLIGHT_TMP" "$PREFLIGHT_DST"
PREFLIGHT_TMP=
PREFLIGHT_REPLACED=1

# Loading PVE::Storage exercises the custom-plugin loader, API compatibility,
# registration and schema initialization; a plain 'use plugin' does not.
perl -MPVE::Storage -e '
    my $plugin = PVE::Storage::Plugin->lookup("zfsiscsimp");
    die "zfsiscsimp did not register\n" if !$plugin;
    my $api = $plugin->api();
    my ($ver, $age) = (PVE::Storage::APIVER, PVE::Storage::APIAGE);
    die "API incompatible: plugin=$api PVE supports [" . ($ver - $age) . "..$ver]\n"
        if $api > $ver || $api < $ver - $age;
    my $plugin_version = $plugin->can("plugin_version") ? $plugin->plugin_version() : "unknown";
    print "    plugin registrado, version=$plugin_version api=$api (PVE $ver, age $age)\n";
'

if [ ! -f /etc/multipath.conf ]; then
    echo "==> instalar /etc/multipath.conf desde el ejemplo"
    install -m 0644 "$MP_SRC" /etc/multipath.conf
    MP_INSTALLED=1
else
    echo "==> /etc/multipath.conf ya existe - validar sin reemplazar"
fi
multipath -t >/dev/null
systemctl reload-or-restart multipathd

# Every long-running daemon that loads PVE::Storage caches the plugin registry,
# including the HA stack. A drained node is required so these restarts cannot
# perturb running HA workloads during a production rollout.
echo "==> recargar daemons que cachean PVE::Storage"
printf '    %s\n' "${STORAGE_DAEMONS[*]}"
for service in "${STORAGE_DAEMONS[@]}"; do
    systemctl reload-or-restart "$service"
    systemctl is-active --quiet "$service" || {
        echo "daemon $service no quedo activo" >&2
        exit 1
    }
done

echo "==> ejecutar gate post-instalacion"
"$PREFLIGHT_DST" --local-only

COMMITTED=1

# Retain a bounded local rollback history. Package-based deployment remains the
# preferred rollback mechanism; these copies only protect manual installs.
for destination in "$PLUGIN_DST" "$PREFLIGHT_DST"; do
    mapfile -t backups < <(ls -1t -- "${destination}.bak."* 2>/dev/null || true)
    if [ "${#backups[@]}" -gt 5 ]; then
        for ((index=5; index<${#backups[@]}; index++)); do
            rm -f -- "${backups[$index]}"
        done
    fi
done

cat <<'NEXT'

Plugin instalado y validado. Pasos operativos:
  1. Repetir en cada nodo PVE antes de habilitarlo para HA/migracion.
  2. Ejecutar zfsiscsimp-preflight --cluster al finalizar el rollout.
  3. Para upgrades mayores, usar el runbook de docs/UPGRADES.md.
NEXT
