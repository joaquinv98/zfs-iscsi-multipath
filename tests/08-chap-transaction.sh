#!/bin/bash
# Simulate a failed storage.cfg commit after the CHAP update hook staged a secret.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

PWFILE="/etc/pve/priv/storage/${STORAGE}.zfsiscsimp-chap"
BACKUP=$(mktemp /run/zfsiscsimp-chap-backup.XXXXXX)
RESTORED=0

restore_secret() {
    [ "$RESTORED" -eq 0 ] || return 0
    PWFILE="$PWFILE" BACKUP="$BACKUP" perl -MPVE::Tools -e '
        open(my $fh, "<", $ENV{BACKUP}) or die "$!\n";
        local $/;
        my $contents = <$fh>;
        close($fh);
        PVE::Tools::file_set_contents($ENV{PWFILE}, $contents, 0600, 1);
    '
    RESTORED=1
}

cleanup() {
    local rc=$?
    set +e
    restore_secret
    rm -f -- "$BACKUP"
    exit "$rc"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "${CONFIRM_DESTRUCTIVE:-}" = YES ] ||
    die "set CONFIRM_DESTRUCTIVE=YES; this test briefly stages a cluster CHAP secret"
[ -s "$PWFILE" ] || die "CHAP file missing for $STORAGE"

cp -- "$PWFILE" "$BACKUP"
chmod 0600 "$BACKUP"
CFG_BEFORE=$(sha256sum /etc/pve/storage.cfg | awk '{print $1}')
SECRET_BEFORE=$(sha256sum "$PWFILE" | awk '{print $1}')
NEW_PASSWORD="uncommitted-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"

log "stage a new password through the real hook but deliberately skip write_config"
STAGED_GENERATION=$(STORAGE="$STORAGE" NEW_PASSWORD="$NEW_PASSWORD" perl -MPVE::Storage -e '
    my $cfg = PVE::Storage::config();
    my $scfg = $cfg->{ids}->{$ENV{STORAGE}} or die "storage missing\n";
    die "CHAP is not configured\n" if !defined($scfg->{chapuser});
    my $plugin = PVE::Storage::Plugin->lookup("zfsiscsimp") or die "plugin missing\n";
    my $update = {};
    my $delete;
    my $sensitive = { password => $ENV{NEW_PASSWORD} };
    $plugin->on_update_hook_full($ENV{STORAGE}, $scfg, $update, $delete, $sensitive);
    my $generation = $update->{"chap-secret-generation"}
        or die "hook did not generate a transactional secret binding\n";
    die "hook did not normalize the delete list\n" if ref($delete) ne "ARRAY";
    print "$generation\n";
')

[ "$(sha256sum /etc/pve/storage.cfg | awk '{print $1}')" = "$CFG_BEFORE" ] ||
    die "test unexpectedly modified storage.cfg"
[ "$(sha256sum "$PWFILE" | awk '{print $1}')" != "$SECRET_BEFORE" ] ||
    die "hook did not stage a new secret record"

log "the still-committed generation must resolve to the original password"
STORAGE="$STORAGE" BACKUP="$BACKUP" PWFILE="$PWFILE" perl -MPVE::Storage -MJSON=decode_json -e '
    sub parse_file {
        my ($path) = @_;
        open(my $fh, "<", $path) or die "$!\n";
        my $raw = <$fh>;
        close($fh);
        chomp($raw //= "");
        my $prefix = "zfsiscsimp-secret-v1:";
        return { legacy => $raw } if index($raw, $prefix) != 0;
        return decode_json(substr($raw, length($prefix)))->{secrets};
    }
    my $cfg = PVE::Storage::config();
    my $scfg = $cfg->{ids}->{$ENV{STORAGE}};
    my $key = $scfg->{"chap-secret-generation"} // "legacy";
    my $old = parse_file($ENV{BACKUP});
    my $staged = parse_file($ENV{PWFILE});
    die "committed secret changed before storage.cfg commit\n"
        if !defined($old->{$key}) || !defined($staged->{$key}) || $old->{$key} ne $staged->{$key};
'
pvesm status --storage "$STORAGE" >/dev/null

restore_secret
[ "$(sha256sum "$PWFILE" | awk '{print $1}')" = "$SECRET_BEFORE" ] ||
    die "original secret was not restored"

echo "CHAP_TRANSACTION_OK staged_generation=$STAGED_GENERATION storage_cfg_sha256=$CFG_BEFORE"
