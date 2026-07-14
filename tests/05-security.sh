#!/bin/bash
# Prove that discovery and normal login reject clients without CHAP.

# lib.sh is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TEST_PORTAL=${TEST_PORTAL:-$PORTAL_B}
PORTAL_WITH_PORT=${TEST_PORTAL}:3260
PVESTATD_STOPPED=0

cleanup() {
    local rc=$?
    set +e
    pvesm status --storage "$STORAGE" >/dev/null 2>&1 || true
    [ "$PVESTATD_STOPPED" -eq 1 ] && systemctl start pvestatd
    exit "$rc"
}
trap cleanup EXIT INT TERM

require_test_confirmation

while read -r vmid; do
    [ -n "$vmid" ] || continue
    qm config "$vmid" | grep -q "${STORAGE}:" &&
        die "running VM $vmid uses $STORAGE; security test logs out one path"
done < <(qm list | awk '$3 == "running" { print $1 }')

CHAPUSER=$(STORAGE="$STORAGE" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    print $cfg->{ids}->{$ENV{STORAGE}}->{chapuser} // "";
')
[ -n "$CHAPUSER" ] || die "storage '$STORAGE' has no chapuser configured"
PWFILE="/etc/pve/priv/storage/${STORAGE}.zfsiscsimp-chap"
[ -s "$PWFILE" ] || die "CHAP password file is missing"
[ "$(stat -c %a "$PWFILE")" = 600 ] || die "CHAP password file is not mode 0600"

systemctl stop pvestatd
PVESTATD_STOPPED=1

log "unauthenticated SendTargets must be rejected"
for setting in discovery.sendtargets.auth.username discovery.sendtargets.auth.password; do
    iscsiadm -m discoverydb -t sendtargets -p "$PORTAL_WITH_PORT" --op update \
        -n "$setting" -v ''
done
iscsiadm -m discoverydb -t sendtargets -p "$PORTAL_WITH_PORT" --op update \
    -n discovery.sendtargets.auth.authmethod -v None
if iscsiadm -m discoverydb -t sendtargets -p "$PORTAL_WITH_PORT" --discover \
    >"/tmp/${STORAGE}-unauth-discovery.out" 2>&1; then
    die "unauthenticated discovery unexpectedly succeeded"
fi
grep -Eqi 'auth|authorization' "/tmp/${STORAGE}-unauth-discovery.out" ||
    die "discovery failed, but not because authentication was rejected"

log "unauthenticated session login must be rejected while the other path stays live"
iscsiadm -m node -T "$TARGET" -p "$PORTAL_WITH_PORT" --logout
for setting in node.session.auth.username node.session.auth.password; do
    iscsiadm -m node -T "$TARGET" -p "$PORTAL_WITH_PORT" --op update \
        -n "$setting" -v ''
done
iscsiadm -m node -T "$TARGET" -p "$PORTAL_WITH_PORT" --op update \
    -n node.session.auth.authmethod -v None
if iscsiadm -m node -T "$TARGET" -p "$PORTAL_WITH_PORT" --login \
    >"/tmp/${STORAGE}-unauth-login.out" 2>&1; then
    die "unauthenticated login unexpectedly succeeded"
fi
grep -Eqi 'auth|authorization' "/tmp/${STORAGE}-unauth-login.out" ||
    die "login failed, but not because authentication was rejected"

log "plugin restores CHAP and both sessions"
pvesm status --storage "$STORAGE" >/dev/null
[ "$(iscsiadm -m session | grep -c "$TARGET")" -eq 2 ] ||
    die "both authenticated sessions were not restored"

echo "SECURITY_OK chapuser=$CHAPUSER rejected_portal=$PORTAL_WITH_PORT"
