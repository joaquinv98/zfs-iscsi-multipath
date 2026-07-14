#!/bin/bash
set -Eeuo pipefail

BASE_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$BASE_DIR"

# Preserve executable policy even when the checkout lives on NTFS/CIFS.
chmod 0755 debian/rules debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm \
    bin/zfsiscsimp-preflight
dpkg-buildpackage -b -us -uc
