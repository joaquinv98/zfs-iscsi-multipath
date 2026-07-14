#!/bin/bash
# Upgrade certification entry point: static/cluster gate plus optional destructive tests.

set -Eeuo pipefail

STORAGE=${STORAGE:-mptest}
PREFLIGHT=${PREFLIGHT:-/usr/sbin/zfsiscsimp-preflight}
RUN_CLUSTER_GATE=${RUN_CLUSTER_GATE:-1}
RUN_DESTRUCTIVE=${RUN_DESTRUCTIVE:-0}
BASE_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -x "$PREFLIGHT" ] || { echo "$PREFLIGHT is not installed" >&2; exit 1; }

"$PREFLIGHT" --local-only --storage "$STORAGE"
if [ "$RUN_CLUSTER_GATE" -eq 1 ]; then
    "$PREFLIGHT" --cluster --storage "$STORAGE"
fi

if [ "$RUN_DESTRUCTIVE" -eq 1 ]; then
    export CONFIRM_DESTRUCTIVE=YES STORAGE
    VMID=9910 TEST_SIZE=1G "$BASE_DIR/00-smoke-lifecycle.sh"
    VMID=9911 TEST_SIZE=1G "$BASE_DIR/07-identity-fail-closed.sh"
    "$BASE_DIR/08-chap-transaction.sh"
else
    echo "UPGRADE_GATE_NONDESTRUCTIVE_OK (set RUN_DESTRUCTIVE=1 for lifecycle/fail-closed/CHAP tests)"
fi
