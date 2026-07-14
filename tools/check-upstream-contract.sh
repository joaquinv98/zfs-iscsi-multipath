#!/bin/bash
# Detect upstream pve-storage changes even when APIVER does not move.

set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$BASE_DIR/compat/pve-storage.certified"
MODE=${1:---certified}
TMPDIR=$(mktemp -d /tmp/zfsiscsimp-upstream.XXXXXX)
trap 'rm -rf -- "$TMPDIR"' EXIT

case "$MODE" in
    --certified|--head) ;;
    *) echo "usage: $0 [--certified|--head]" >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
CERTIFIED_COMMIT=$(sed -n 's/^commit=//p' "$MANIFEST")
EXPECTED_APIVER=$(sed -n 's/^apiver=//p' "$MANIFEST")
EXPECTED_APIAGE=$(sed -n 's/^apiage=//p' "$MANIFEST")
REF=$CERTIFIED_COMMIT
if [ "$MODE" = --head ]; then
    REF=$(curl -fsSL https://api.github.com/repos/proxmox/pve-storage/commits/master |
        perl -MJSON=decode_json -0777 -e 'print decode_json(<>)->{sha}')
fi

CHANGED=0
while read -r expected path; do
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || continue
    destination="$TMPDIR/$path"
    install -d "$(dirname "$destination")"
    curl -fsSL "https://raw.githubusercontent.com/proxmox/pve-storage/$REF/$path" \
        -o "$destination"
    actual=$(sha256sum "$destination" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        if [ "$MODE" = --certified ]; then
            echo "certified source hash mismatch: $path" >&2
            exit 1
        fi
        echo "UPSTREAM_CHANGED $path expected=$expected actual=$actual" >&2
        CHANGED=1
    fi
done <"$MANIFEST"

STORAGE_PM="$TMPDIR/src/PVE/Storage.pm"
PLUGIN_PM="$TMPDIR/src/PVE/Storage/Plugin.pm"
ZFS_PM="$TMPDIR/src/PVE/Storage/ZFSPlugin.pm"
LIO_PM="$TMPDIR/src/PVE/Storage/LunCmd/LIO.pm"

APIVER=$(sed -n 's/.*use constant APIVER => \([0-9][0-9]*\).*/\1/p' "$STORAGE_PM" | head -n1)
APIAGE=$(sed -n 's/.*use constant APIAGE => \([0-9][0-9]*\).*/\1/p' "$STORAGE_PM" | head -n1)
[ "$APIVER" = "$EXPECTED_APIVER" ] || {
    echo "APIVER changed: certified=$EXPECTED_APIVER upstream=$APIVER" >&2
    exit 1
}
[ "$APIAGE" = "$EXPECTED_APIAGE" ] || {
    echo "APIAGE changed: certified=$EXPECTED_APIAGE upstream=$APIAGE" >&2
    exit 1
}

require_contract() {
    local file=$1 text=$2 label=$3
    grep -Fq "$text" "$file" || {
        echo "upstream contract changed: $label" >&2
        exit 1
    }
}

require_contract "$STORAGE_PM" "my \$min_version = (APIVER - APIAGE);" "custom loader API window"
# Literal Perl signatures intentionally use single quotes.
# shellcheck disable=SC2016
require_contract "$PLUGIN_PM" 'my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;' \
    "on_update_hook_full signature"
# shellcheck disable=SC2016
require_contract "$ZFS_PM" 'my ($class, $scfg, $timeout, $method, @params) = @_;' \
    "zfs_request signature"
# shellcheck disable=SC2016
require_contract "$ZFS_PM" 'my ($class, $storeid, $scfg, $volname, $isBase) = @_;' \
    "free_image signature"
# shellcheck disable=SC2016
require_contract "$ZFS_PM" 'my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;' \
    "volume_resize signature"
# shellcheck disable=SC2016
require_contract "$ZFS_PM" 'my ($class, $scfg, $storeid, $volname, $snap) = @_;' \
    "volume_snapshot_rollback signature"
require_contract "$LIO_PM" '/etc/rtslib-fb-target/saveconfig.json' "LIO saveconfig path"
require_contract "$LIO_PM" "'saveconfig'" "LIO explicit saveconfig"

LOCAL_API=$(sed -n 's/^sub api { return \([0-9][0-9]*\); }/\1/p' \
    "$BASE_DIR/src/PVE/Storage/Custom/ZFSiSCSIMPPlugin.pm")
[ -n "$LOCAL_API" ] || { echo "unable to parse local plugin API" >&2; exit 1; }
if [ "$LOCAL_API" -gt "$APIVER" ] || [ "$LOCAL_API" -lt $((APIVER - APIAGE)) ]; then
    echo "local plugin API $LOCAL_API is outside [$((APIVER-APIAGE))..$APIVER]" >&2
    exit 1
fi

if [ "$MODE" = --head ] && [ "$CHANGED" -ne 0 ]; then
    echo "UPSTREAM_REVIEW_REQUIRED ref=$REF" >&2
    exit 2
fi

echo "UPSTREAM_CONTRACT_OK ref=$REF api=$APIVER age=$APIAGE local_api=$LOCAL_API"
