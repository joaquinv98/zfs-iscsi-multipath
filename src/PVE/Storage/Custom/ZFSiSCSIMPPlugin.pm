# SPDX-License-Identifier: AGPL-3.0-or-later
#
# zfsiscsimp - ZFS over iSCSI with kernel initiator + dm-multipath for Proxmox VE
# Copyright (C) 2026 NeaTech
#
# Derived from PVE::Storage::ZFSPlugin (pve-storage, AGPL-3.0-or-later).
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. See the LICENSE file for the full text.

package PVE::Storage::Custom::ZFSiSCSIMPPlugin;

use strict;
use warnings;

use JSON qw(decode_json encode_json);
use Time::HiRes qw(usleep);

use PVE::Tools qw(file_read_firstline file_set_contents run_command);
use PVE::Storage::Plugin;
use PVE::Storage::ZFSPlugin;

use base qw(PVE::Storage::ZFSPlugin);

our $VERSION = '0.3.3';

# ZFS over iSCSI with the kernel initiator and dm-multipath.
#
# Storage-side management (zvol lifecycle over ssh, LUN lifecycle via
# LunCmd) is inherited unchanged from the stock 'zfs' plugin. What changes
# is how volumes are consumed on the PVE node: instead of handing QEMU an
# iscsi:// URL (libiscsi, single portal, no MPIO), this plugin logs the
# node's open-iscsi initiator into every configured portal, lets
# dm-multipath assemble the paths, and hands QEMU the multipath device.
#
# Requirements on the node: open-iscsi and multipath-tools installed and
# running, and every portal reachable.
# Requirements on the target: all portals in the same TPG (same LUN list,
# same backstores), which the stock LIO setup for ZFS over iSCSI already
# gives you by adding a second portal to the TPG.
#
# Set 'shared 1' in storage.cfg: the custom type is not in the core
# @SHARED_STORAGE list, so PVE does not force it, and without it live
# migration and HA treat the LUN as node-local.

my @ssh_opts = (
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=3',
    '-o', 'ConnectionAttempts=1',
);
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';

my $ISCSIADM = '/usr/bin/iscsiadm';
my $MULTIPATH = '/sbin/multipath';
my $MULTIPATHD = '/sbin/multipathd';
my $BLOCKDEV = '/usr/sbin/blockdev';

sub type { return 'zfsiscsimp'; }

sub plugin_version { return $VERSION; }

sub plugindata {
    return {
        content => [{ images => 1 }, { images => 1 }],
        'sensitive-properties' => { password => 1 },
    };
}

sub api { return 15; }

sub properties {
    return {
        extraportals => {
            description => "Additional iSCSI portal(s) of the same target and TPG,"
                . " comma separated (host or host:port). The kernel initiator logs"
                . " into every portal and dm-multipath aggregates the paths.",
            type => 'string',
        },
        chapuser => {
            description => "Optional CHAP username for the iSCSI sessions.",
            type => 'string',
            pattern => '[^\\s:]{1,223}',
        },
        'chap-secret-generation' => {
            description => "Internal generation that atomically binds storage.cfg to a CHAP secret.",
            type => 'string',
            pattern => '[0-9a-f]{32}',
        },
    };
}

sub options {
    return {
        nodes => { optional => 1 },
        disable => { optional => 1 },
        shared => { fixed => 1 },
        portal => { fixed => 1 },
        extraportals => { optional => 1 },
        target => { fixed => 1 },
        pool => { fixed => 1 },
        blocksize => { fixed => 1 },
        iscsiprovider => { fixed => 1 },
        nowritecache => { optional => 1 },
        sparse => { optional => 1 },
        comstar_hg => { optional => 1 },
        comstar_tg => { optional => 1 },
        lio_tpg => { fixed => 1 },
        chapuser => { optional => 1 },
        'chap-secret-generation' => { optional => 1 },
        password => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
        'zfs-base-path' => { optional => 1 },
    };
}

# host and (optional) port of a portal entry; the iSCSI default port is 3260
my $split_portal = sub {
    my ($entry) = @_;
    $entry //= '';
    $entry =~ s/^\s+|\s+$//g;

    my ($host, $port);
    # IPv6 in brackets: [::1]:3260
    if ($entry =~ m/^\[(.+)\]:(\d+)$/) {
        ($host, $port) = ($1, $2);
    } elsif ($entry =~ m/^\[(.+)\]$/) {
        ($host, $port) = ($1, 3260);
    } elsif ($entry =~ m/^(.+):(\d+)$/ && $entry !~ m/:.*:/) {
        # host:port, but not a bare IPv6 literal (which has multiple colons)
        ($host, $port) = ($1, $2);
    } else {
        ($host, $port) = ($entry, 3260);
    }

    die "invalid empty iSCSI portal\n" if !length($host);
    die "invalid iSCSI port '$port' in portal '$entry'\n" if $port < 1 || $port > 65535;
    return ($host, int($port));
};

my $format_portal = sub {
    my ($host, $port) = @_;
    return $host =~ /:/ ? "[$host]:$port" : "$host:$port";
};

my $all_portals = sub {
    my ($scfg) = @_;
    my @portals = ($scfg->{portal});
    push @portals, split(/[,;\s]+/, $scfg->{extraportals} // '');

    my %seen;
    my @result;
    for my $portal (grep { defined($_) && length($_) } @portals) {
        my ($host, $port) = $split_portal->($portal);
        my $normalized = $format_portal->($host, $port);
        next if $seen{lc($normalized)}++;
        push @result, $normalized;
    }
    return @result;
};

my $validate_config = sub {
    my ($scfg) = @_;
    die "zfsiscsimp only supports iscsiprovider 'LIO'\n"
        if ($scfg->{iscsiprovider} // '') ne 'LIO';
    die "zfsiscsimp requires lio_tpg in the form tpgN\n"
        if ($scfg->{lio_tpg} // '') !~ /^tpg\d+$/;
    die "zfsiscsimp requires 'shared 1' for correct HA and migration semantics\n"
        if !$scfg->{shared};
    my @portals = $all_portals->($scfg);
    die "zfsiscsimp requires at least two distinct portals\n" if @portals < 2;
    return 1;
};

my $chap_password_file = sub {
    my ($storeid) = @_;
    return "/etc/pve/priv/storage/${storeid}.zfsiscsimp-chap";
};

my $CHAP_SECRET_PREFIX = 'zfsiscsimp-secret-v1:';

my $validate_chap_password = sub {
    my ($password) = @_;
    die "CHAP password must contain between 12 and 255 characters\n"
        if !defined($password) || length($password) < 12 || length($password) > 255;
    die "CHAP password must not contain control characters\n"
        if $password =~ /[\x00-\x1f\x7f]/;
};

my $new_chap_generation = sub {
    open(my $urandom, '<', '/dev/urandom')
        or die "unable to open /dev/urandom for CHAP generation: $!\n";
    my $bytes = '';
    my $read = read($urandom, $bytes, 16);
    close($urandom);
    die "unable to read a CHAP generation from /dev/urandom\n"
        if !defined($read) || $read != 16;
    return unpack('H*', $bytes);
};

my $read_chap_record = sub {
    my ($storeid) = @_;
    my $path = $chap_password_file->($storeid);
    return undef if !-e $path;

    my $raw = file_read_firstline($path);
    return undef if !defined($raw);

    # Upgrade legacy 0.2.x plaintext files lazily. They remain readable until
    # the next password rotation creates a generation-bound record.
    return { legacy => $raw } if index($raw, $CHAP_SECRET_PREFIX) != 0;

    my $json = substr($raw, length($CHAP_SECRET_PREFIX));
    my $record = eval { decode_json($json) };
    die "CHAP secret record '$path' is corrupt: " . ($@ || 'invalid structure') . "\n"
        if !defined($record) || ref($record) ne 'HASH'
        || ref($record->{secrets}) ne 'HASH';
    return $record->{secrets};
};

my $write_chap_record = sub {
    my ($storeid, $secrets) = @_;
    my $dir = '/etc/pve/priv/storage';
    mkdir($dir) if !-d $dir;
    die "unable to create CHAP secret directory '$dir': $!\n" if !-d $dir;

    my $path = $chap_password_file->($storeid);
    my $payload = $CHAP_SECRET_PREFIX . encode_json({ secrets => $secrets }) . "\n";
    # file_set_contents is already atomic (tmp+rename); its 4th positional arg
    # is force_utf8, which would double-encode the already-UTF-8 JSON payload
    # and silently corrupt non-ASCII CHAP secrets. Never pass it here.
    # No extra locking needed: the add/update hooks run under the cfs storage
    # lock and the write is an atomic rename.
    file_set_contents($path, $payload, 0600);
};

my $get_chap_password = sub {
    my ($storeid, $scfg) = @_;
    my $secrets = $read_chap_record->($storeid);
    return undef if !defined($secrets);

    my $generation = $scfg->{'chap-secret-generation'};
    return $secrets->{$generation} if defined($generation);
    return $secrets->{legacy};
};

my $stage_chap_password = sub {
    my ($storeid, $scfg, $password) = @_;
    $validate_chap_password->($password);

    # Keep exactly the currently committed password and the proposed one.
    # Before storage.cfg commits, readers select the old generation; after it
    # commits, they select the new generation. A failed pmxcfs write therefore
    # cannot switch authentication credentials underneath the old config.
    my %secrets;
    if (defined($scfg)) {
        my $current = $get_chap_password->($storeid, $scfg);
        if (defined($current)) {
            my $key = $scfg->{'chap-secret-generation'} // 'legacy';
            $secrets{$key} = $current;
        }
    }

    my $generation = $new_chap_generation->();
    $secrets{$generation} = $password;
    $write_chap_record->($storeid, \%secrets);
    return $generation;
};

my $ssh_key_for_host = sub {
    my ($scfg, $host) = @_;
    my $key = "$id_rsa_path/${host}_id_rsa";
    return -e $key ? $key : undef;
};

my $control_cache = {};

my $ordered_control_hosts = sub {
    my ($scfg) = @_;
    my @hosts = map { ($split_portal->($_))[0] } $all_portals->($scfg);
    my $cachekey = join('|', $scfg->{target}, @hosts);
    my $cached = $control_cache->{$cachekey};
    if ($cached && time() - $cached->[0] < 30) {
        @hosts = ($cached->[1], grep { $_ ne $cached->[1] } @hosts);
    }
    return ($cachekey, @hosts);
};

my $scfg_for_control_host = sub {
    my ($scfg, $host) = @_;
    my $copy = { %$scfg };
    $copy->{portal} = $host;
    return $copy;
};

my $select_control_scfg = sub {
    my ($scfg) = @_;
    my ($cachekey, @hosts) = $ordered_control_hosts->($scfg);
    my @errors;
    for my $host (@hosts) {
        my $key = $ssh_key_for_host->($scfg, $host);
        if (!defined($key)) {
            push @errors, "$host: SSH key missing";
            next;
        }
        my $rc = eval {
            run_command(
                [@ssh_cmd, '-i', $key, "root\@$host", '--', 'true'],
                noerr => 1,
                quiet => 1,
                timeout => 5,
            );
        };
        if (defined($rc) && $rc == 0) {
            $control_cache->{$cachekey} = [time(), $host];
            return $scfg_for_control_host->($scfg, $host);
        }
        push @errors, "$host: " . ($@ || "SSH probe failed (rc=" . (defined($rc) ? $rc : 'undef') . ")");
    }
    die "no reachable SSH control portal for '$scfg->{target}': " . join('; ', @errors) . "\n";
};

# The stock ZFS-over-iSCSI implementation uses only scfg->{portal} for its SSH
# control plane. Read-only operations may safely fail over and be retried. For
# mutating operations, probe all portals first and execute exactly once on the
# selected host to avoid replaying a partially completed target operation.
sub zfs_request {
    my ($class, $scfg, $timeout, $method, @params) = @_;

    my %read_only = map { $_ => 1 } qw(get list list_lu list_view zpool_list);
    if (!$read_only{$method}) {
        my $selected = $select_control_scfg->($scfg);
        return $class->SUPER::zfs_request($selected, $timeout, $method, @params);
    }

    my $selected = $select_control_scfg->($scfg);
    my $selected_host = $selected->{portal};
    my ($cachekey, @hosts) = $ordered_control_hosts->($scfg);
    @hosts = ($selected_host, grep { $_ ne $selected_host } @hosts);
    my @errors;
    for my $host (@hosts) {
        next if !defined($ssh_key_for_host->($scfg, $host));
        my $copy = $scfg_for_control_host->($scfg, $host);
        my $result = eval { $class->SUPER::zfs_request($copy, $timeout, $method, @params) };
        if (!$@) {
            $control_cache->{$cachekey} = [time(), $host];
            return $result;
        }
        push @errors, "$host: $@";
    }
    die "control operation '$method' failed through every portal: " . join('; ', @errors) . "\n";
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    die "chap-secret-generation is managed internally; provide password instead\n"
        if defined($scfg->{'chap-secret-generation'});
    $validate_config->($scfg);
    die "chapuser requires a password\n"
        if defined($scfg->{chapuser}) && !defined($sensitive{password});
    die "password requires chapuser\n"
        if !defined($scfg->{chapuser}) && defined($sensitive{password});
    if (defined($sensitive{password})) {
        $scfg->{'chap-secret-generation'} =
            $stage_chap_password->($storeid, undef, $sensitive{password});
    }

    my $selected = $select_control_scfg->($scfg);
    $class->SUPER::on_add_hook($storeid, $selected);
    $scfg->{'zfs-base-path'} = $selected->{'zfs-base-path'}
        if defined($selected->{'zfs-base-path'});
    return;
}

sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;
    if (!defined($delete)) {
        $delete = [];
        $_[4] = $delete; # let the API apply internal post-hook deletions
    }

    die "chap-secret-generation is managed internally; update password instead\n"
        if exists($update->{'chap-secret-generation'});
    my $deletes_generation = grep { $_ eq 'chap-secret-generation' } @$delete;
    die "chap-secret-generation is managed internally; delete password instead\n"
        if $deletes_generation && !exists($sensitive->{password});

    my $merged = { %$scfg, %$update };
    delete $merged->{$_} for @$delete;
    $validate_config->($merged);

    # Validate the chapuser/password invariant against the RESULT before
    # mutating the secret file: deleting the password while chapuser stays
    # must be rejected without first unlinking the secret (which is
    # cluster-wide via pmxcfs and would brick activation on every node).
    my $password_after;
    if (defined($merged->{chapuser})) {
        $password_after = exists($sensitive->{password})
            ? $sensitive->{password}
            : (defined($scfg->{chapuser}) ? $get_chap_password->($storeid, $scfg) : undef);
        die "chapuser requires a stored password\n" if !defined($password_after);
    } else {
        die "password requires chapuser\n"
            if exists($sensitive->{password}) && defined($sensitive->{password});
        # Removing chapuser also detaches the committed generation. The secret
        # record itself stays until post-commit garbage collection.
        push @$delete, 'chap-secret-generation'
            if defined($scfg->{'chap-secret-generation'}) && !$deletes_generation;
    }

    if (exists($sensitive->{password})) {
        if (defined($sensitive->{password})) {
            my $generation = $stage_chap_password->($storeid, $scfg, $sensitive->{password});
            $update->{'chap-secret-generation'} = $generation;
            @$delete = grep { $_ ne 'chap-secret-generation' } @$delete;
        } else {
            # Do not unlink the old secret before storage.cfg commits. Once
            # chapuser and its generation disappear it is unreachable; an
            # explicit secret GC can safely remove the orphan later.
            push @$delete, 'chap-secret-generation'
                if !grep { $_ eq 'chap-secret-generation' } @$delete;
        }
    }
    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;
    # This hook runs before storage.cfg commits. Removing the secret here would
    # leave a still-configured storage unusable if the pmxcfs write then failed.
    # Keep the mode-0600 orphan; zfsiscsimp-preflight --cleanup-secrets removes
    # it only after it can prove the storage ID no longer exists.
    return;
}

# --- WWID of the LIO backstore backing a volume -----------------------------
#
# LunCmd::LIO names backstores '<pool with / replaced by -> + - + <volname>'
# and lets LIO generate the unit serial. dm-multipath names a LIO LUN by the
# id /lib/udev/scsi_id returns: '3' (NAA type) + '6001405' (NAA header + LIO
# IEEE OUI 0x001405) + the first 25 hex digits of the unit serial. We read the
# serial from storage_objects[].wwn in the target's saveconfig.json, which
# LunCmd::LIO rewrites (targetcli saveconfig) after every LUN change.

my $identity_cache = {};
my $IDENTITY_CACHE_TTL = 15;

my $read_saveconfig = sub {
    my ($scfg) = @_;

    # Probe once, then read through the known-reachable host first. Without
    # this ordering a black-holed host costs one SSH timeout per candidate
    # saveconfig path before failover.
    my @portals = $all_portals->($scfg);
    my $selected = eval { $select_control_scfg->($scfg) };
    if (defined($selected)) {
        my $selected_host = $selected->{portal};
        @portals = (
            grep { ($split_portal->($_))[0] eq $selected_host } @portals,
            grep { ($split_portal->($_))[0] ne $selected_host } @portals,
        );
    }

    for my $portal (@portals) {
        my ($host) = $split_portal->($portal);
        my $key = $ssh_key_for_host->($scfg, $host);
        next if !defined($key);

        for my $cfgpath ('/etc/rtslib-fb-target/saveconfig.json', '/etc/target/saveconfig.json') {
            my $out = '';
            my $cmd = [@ssh_cmd, '-i', $key, "root\@$host", 'cat', $cfgpath];
            my $rc = eval {
                run_command(
                    $cmd,
                    # ConnectTimeout only bounds the handshake; a wedged target
                    # that accepts the connection but hangs in cat would block a
                    # worker forever without this overall timeout.
                    timeout => 10,
                    outfunc => sub { $out .= "$_[0]\n"; },
                    errfunc => sub { },
                    noerr => 1,
                    quiet => 1,
                );
            };
            next if !defined($rc) || $rc != 0 || $out !~ /\S/;
            my $config = eval { decode_json($out) };
            return $config if defined($config);
        }
    }
    return undef;
};

my $backstore_name = sub {
    my ($scfg, $volname) = @_;
    my $prefix = $scfg->{pool};
    $prefix =~ s|/|-|g;
    return "$prefix-$volname";
};

my $zfsmp_resolve_identity = sub {
    my ($scfg, $volname) = @_;

    my $bsname = $backstore_name->($scfg, $volname);
    my $cachekey = "$scfg->{target}/$bsname";
    my $entry = $identity_cache->{$cachekey};
    return { status => 'ok', identity => $entry }
        if $entry && time() - $entry->{time} < $IDENTITY_CACHE_TTL;

    my $config = $read_saveconfig->($scfg);
    return {
        status => 'unavailable',
        cached_identity => $entry,
        error => "unable to read the LIO saveconfig from any portal of '$scfg->{target}'",
    } if !defined($config);
    return {
        status => 'invalid',
        cached_identity => $entry,
        error => "LIO saveconfig for '$scfg->{target}' has no storage_objects array",
    } if ref($config) ne 'HASH' || ref($config->{storage_objects}) ne 'ARRAY';

    my ($serial, $actual_bsname);
    for my $so (@{ $config->{storage_objects} }) {
        next if ref($so) ne 'HASH';
        next if !defined($so->{name}) || !defined($so->{wwn});
        next if defined($so->{plugin}) && $so->{plugin} ne 'block';
        if ($so->{name} eq $bsname) {
            ($serial, $actual_bsname) = ($so->{wwn}, $bsname);
            last;
        }
        # legacy backstores created without the pool prefix
        if ($so->{name} eq $volname && !defined($serial)) {
            ($serial, $actual_bsname) = ($so->{wwn}, $volname);
        }
    }
    return {
        status => 'absent',
        cached_identity => $entry,
        error => "backstore for volume '$volname' not found on target '$scfg->{target}'",
    } if !defined($serial);

    my $hex = lc($serial);
    $hex =~ s/[^0-9a-f]//g;
    return {
        status => 'invalid',
        cached_identity => $entry,
        error => "unit serial '$serial' of volume '$volname' is too short for a NAA id",
    } if length($hex) < 25;

    return {
        status => 'invalid',
        cached_identity => $entry,
        error => "LIO saveconfig for '$scfg->{target}' has no targets array",
    } if ref($config->{targets}) ne 'ARRAY';

    my ($tpg_tag) = $scfg->{lio_tpg} =~ /^tpg(\d+)$/;
    my $lun;
    TARGET:
    for my $target (@{ $config->{targets} }) {
        next if ref($target) ne 'HASH';
        next if ($target->{fabric} // '') ne 'iscsi';
        next if ($target->{wwn} // '') ne $scfg->{target};
        next if ref($target->{tpgs}) ne 'ARRAY';
        for my $tpg (@{ $target->{tpgs} }) {
            next if ref($tpg) ne 'HASH';
            next if !defined($tpg->{tag}) || $tpg->{tag} != $tpg_tag;
            next if ref($tpg->{luns}) ne 'ARRAY';
            for my $candidate (@{ $tpg->{luns} }) {
                next if ref($candidate) ne 'HASH';
                next if ($candidate->{storage_object} // '')
                    ne "/backstores/block/$actual_bsname";
                $lun = $candidate->{index};
                last TARGET;
            }
        }
    }
    return {
        status => 'invalid',
        cached_identity => $entry,
        error => "LUN for backstore '$actual_bsname' not found in $scfg->{lio_tpg}",
    } if !defined($lun) || $lun !~ /^\d+$/;

    my $identity = {
        time => time(),
        wwid => '36001405' . substr($hex, 0, 25),
        lun => int($lun),
    };
    $identity_cache->{$cachekey} = $identity;
    return { status => 'ok', identity => $identity };
};

my $zfsmp_get_identity = sub {
    my ($scfg, $volname) = @_;
    my $resolved = $zfsmp_resolve_identity->($scfg, $volname);
    return $resolved->{identity} if $resolved->{status} eq 'ok';

    # A stale identity is useful for keeping an already-attached volume
    # operational during a transient control-plane outage. Never use it when
    # the target definitively reports the backstore absent or structurally bad.
    if ($resolved->{status} eq 'unavailable' && $resolved->{cached_identity}) {
        warn "zfsiscsimp: using stale cached identity for '$volname': $resolved->{error}\n";
        return $resolved->{cached_identity};
    }
    die "$resolved->{error}\n";
};

my $zfsmp_get_wwid = sub {
    my ($scfg, $volname) = @_;
    return $zfsmp_get_identity->($scfg, $volname)->{wwid};
};

my $zfsmp_forget_wwid = sub {
    my ($scfg, $volname) = @_;
    my $bsname = $backstore_name->($scfg, $volname);
    delete $identity_cache->{"$scfg->{target}/$bsname"};
};

# Resolve the multipath map device from its WWID independently of
# user_friendly_names / alias: the dm uuid of a multipath map is always
# 'mpath-<wwid>', exposed as a stable /dev/disk/by-id symlink.
my $zfsmp_mapdev = sub {
    my ($wwid) = @_;
    my $byid = "/dev/disk/by-id/dm-uuid-mpath-$wwid";
    return $byid if -b $byid;
    my $direct = "/dev/mapper/$wwid";
    return $direct if -b $direct;
    return undef;
};

# Number of paths which multipathd currently considers usable. Counting sysfs
# slaves alone is insufficient because failed/faulty paths remain attached.
my $zfsmp_path_count = sub {
    my ($wwid) = @_;
    my $count = 0;
    my $rc = eval {
        run_command(
            [$MULTIPATHD, 'show', 'paths', 'raw', 'format', '%w|%d|%t|%o|%T'],
            noerr => 1,
            quiet => 1,
            outfunc => sub {
                my ($line) = @_;
                my ($path_wwid, undef, $dm_state, $dev_state, $checker_state) = split(/\|/, $line);
                $count++
                    if defined($path_wwid)
                    && $path_wwid eq $wwid
                    && ($dm_state // '') eq 'active'
                    && ($dev_state // '') eq 'running'
                    && ($checker_state // '') eq 'ready';
            },
        );
    };
    return 0 if !defined($rc) || $rc != 0;
    return $count;
};

# --- iSCSI session management -----------------------------------------------

my $iscsi_sessions = sub {
    my $sessions = {};
    eval {
        run_command(
            [$ISCSIADM, '-m', 'session'],
            noerr => 1,
            quiet => 1,
            outfunc => sub {
                my ($line) = @_;
                # tcp: [3] 10.90.1.11:3260,1 iqn.example:target (non-flash)
                # tcp: [4] [2001:db8::1]:3260,1 iqn.example:target (non-flash)
                if ($line =~ m/^\S+\s+\[(\d+)\]\s+(\[[^\]]+\]|[^,\s]+):(\d+),\S+\s+(\S+)/) {
                    my ($sid, $host, $port, $target) = ($1, $2, $3, $4);
                    $host =~ s/^\[|\]$//g;
                    $sessions->{lc("$host|$port|$target")} = int($sid);
                }
            },
        );
    };
    return $sessions;
};

my $zfsmp_login_all = sub {
    my ($storeid, $scfg) = @_;

    my $target = $scfg->{target};
    my $sessions = $iscsi_sessions->();
    my @errors;
    my $chap_password = defined($scfg->{chapuser})
        ? $get_chap_password->($storeid, $scfg)
        : undef;
    die "CHAP is configured for '$storeid' but its password file is missing\n"
        if defined($scfg->{chapuser}) && !defined($chap_password);

    for my $portal ($all_portals->($scfg)) {
        my ($host, $port) = $split_portal->($portal);
        my $session_key = lc("$host|$port|$target");
        my $pp = $format_portal->($host, $port);
        eval {
            # Keep a persistent discovery record aligned with the node record.
            # This permits LIO discovery_auth to be enabled without exposing
            # the target inventory to unauthenticated initiators.
            run_command(
                [$ISCSIADM, '-m', 'discoverydb', '-t', 'sendtargets', '-p', $pp, '--op', 'new'],
                noerr => 1, quiet => 1,
            );
            my @discovery_settings = defined($scfg->{chapuser})
                ? (
                    ['discovery.sendtargets.auth.authmethod', 'CHAP'],
                    ['discovery.sendtargets.auth.username', $scfg->{chapuser}],
                    ['discovery.sendtargets.auth.password', $chap_password],
                )
                : (
                    ['discovery.sendtargets.auth.authmethod', 'None'],
                    ['discovery.sendtargets.auth.username', ''],
                    ['discovery.sendtargets.auth.password', ''],
                );
            for my $nv (@discovery_settings) {
                my $update_rc = run_command(
                    [
                        $ISCSIADM, '-m', 'discoverydb', '-t', 'sendtargets', '-p', $pp,
                        '--op', 'update', '-n', $nv->[0], '-v', $nv->[1],
                    ],
                    noerr => 1, quiet => 1,
                );
                die "discovery update '$nv->[0]' failed (rc=$update_rc)\n"
                    if !defined($update_rc) || $update_rc != 0;
            }

            if (!$sessions->{$session_key}) {
                my $discovery_rc = run_command(
                    [
                        $ISCSIADM, '-m', 'discoverydb', '-t', 'sendtargets', '-p', $pp,
                        '--discover',
                    ],
                    noerr => 1, quiet => 1,
                );
                die "discovery failed (rc=$discovery_rc)\n"
                    if !defined($discovery_rc) || $discovery_rc != 0;
            }

            my @settings = (
                ['node.startup', 'manual'],
                # NOP-Out detects black-holed links; replacement_timeout bounds
                # commands already in the SCSI error handler. multipath's
                # fast_io_fail_tmo is the final authority for mapped devices.
                ['node.session.timeo.replacement_timeout', '5'],
                ['node.conn[0].timeo.noop_out_interval', '2'],
                ['node.conn[0].timeo.noop_out_timeout', '2'],
            );
            if (defined($scfg->{chapuser})) {
                push @settings,
                    ['node.session.auth.authmethod', 'CHAP'],
                    ['node.session.auth.username', $scfg->{chapuser}],
                    ['node.session.auth.password', $chap_password];
            } else {
                push @settings,
                    ['node.session.auth.authmethod', 'None'],
                    ['node.session.auth.username', ''],
                    ['node.session.auth.password', ''];
            }

            for my $nv (@settings) {
                my $update_rc = run_command(
                    [
                        $ISCSIADM, '-m', 'node', '-T', $target, '-p', $pp,
                        '--op', 'update', '-n', $nv->[0], '-v', $nv->[1],
                    ],
                    noerr => 1, quiet => 1,
                );
                die "node update '$nv->[0]' failed (rc=$update_rc)\n"
                    if !defined($update_rc) || $update_rc != 0;
            }

            if (!$sessions->{$session_key}) {
                my $login_rc = run_command(
                    [$ISCSIADM, '-m', 'node', '-T', $target, '-p', $pp, '--login'],
                    noerr => 1, quiet => 1,
                );
                if (!defined($login_rc) || $login_rc != 0) {
                    # PVE workers may activate the same storage concurrently.
                    # Treat a racing login as success once the session exists.
                    my $appeared = 0;
                    for (1 .. 10) {
                        if ($iscsi_sessions->()->{$session_key}) {
                            $appeared = 1;
                            last;
                        }
                        usleep(100_000);
                    }
                    die "login failed (rc=" . (defined($login_rc) ? $login_rc : 'undef') . ")\n"
                        if !$appeared;
                }
            }
        };
        push @errors, "$pp: $@" if $@;
    }

    warn "zfsiscsimp: iSCSI login issues for target $target: "
        . join('; ', @errors) . "\n"
        if @errors;

    return $iscsi_sessions->();
};

my $write_sysfs = sub {
    my ($path, $value) = @_;
    open(my $fh, '>', $path) or die "unable to open '$path': $!\n";
    print $fh $value or die "unable to write '$path': $!\n";
    close($fh) or die "unable to close '$path': $!\n";
};

# LIO exposes path identity as naa.<NAA identifier> in sysfs, while
# dm-multipath uses the SCSI designator type (3) followed by that identifier.
# Reading sysfs also works for a stale path after its remote LUN was removed,
# when scsi_id can no longer query the target.
my $zfsmp_block_wwid = sub {
    my ($dev) = @_;
    return undef if $dev !~ /^sd[a-z]+$/;
    my $raw = eval { file_read_firstline("/sys/block/$dev/device/wwid") };
    return undef if !defined($raw);
    $raw =~ s/^\s+|\s+$//g;
    $raw =~ s/^naa\./3/i;
    return lc($raw);
};

my $zfsmp_path_devices = sub {
    my ($wwid) = @_;
    my @devices;
    for my $path (glob('/sys/block/sd*')) {
        next if $path !~ m|/([^/]+)$|;
        my $dev = $1;
        my $path_wwid = $zfsmp_block_wwid->($dev);
        push @devices, $dev if defined($path_wwid) && $path_wwid eq lc($wwid);
    }
    return @devices;
};

my $zfsmp_delete_path_devices = sub {
    my (@devices) = @_;
    my (%seen, @errors);
    for my $dev (grep { !$seen{$_}++ } @devices) {
        if ($dev !~ /^sd[a-z]+$/) {
            push @errors, "$dev: invalid SCSI block-device name";
            next;
        }
        my $delete = "/sys/block/$dev/device/delete";
        if (!-w $delete) {
            push @errors, "$dev: delete endpoint is not writable";
            next;
        }
        eval { $write_sysfs->($delete, "1\n") };
        push @errors, "$dev: $@" if $@;
    }

    for (1 .. 20) {
        last if !grep { -e "/sys/block/$_" } keys(%seen);
        usleep(100_000);
    }
    push @errors, map { "$_: device still present after delete" }
        grep { -e "/sys/block/$_" } keys(%seen);
    return \@errors;
};

# Scan exactly one LUN on each session for this target. This avoids reviving
# every inactive LUN, which iscsiadm --rescan does for the complete session.
my $zfsmp_rescan_lun = sub {
    my ($target, $lun, $resize, $expected_wwid) = @_;
    my $matched = 0;
    for my $session (glob('/sys/class/iscsi_session/session*')) {
        my $session_target = eval { file_read_firstline("$session/targetname") };
        next if !defined($session_target) || $session_target ne $target;

        # Once the last SCSI device is deleted the session has no targetH:C:I
        # child, but its class symlink still identifies the iSCSI host.
        my $session_link = readlink($session) // '';
        next if $session_link !~ m|/host(\d+)/session|;
        my $host = $1;
        my $scan = "/sys/class/scsi_host/host$host/scan";
        die "SCSI scan endpoint '$scan' is not writable\n" if !-w $scan;

        my @scsi_devices = glob("/sys/class/scsi_device/$host:*:*:$lun");
        if (!@scsi_devices) {
            # Wildcard only channel/target, never the LUN, so inactive LUNs
            # on the same session are not rediscovered.
            $write_sysfs->($scan, "- - $lun\n");
            $matched++;
            next;
        }

        for my $scsi_class (@scsi_devices) {
            next if $scsi_class !~ m|/(\d+):(\d+):(\d+):(\d+)$|;
            my ($device_host, $channel, $id) = ($1, $2, $3);
            next if $device_host != $host;
            my $scsi_device = "$scsi_class/device";
            my $rescan = "$scsi_device/rescan";

            # LIO may reuse a numeric LUN immediately after free. A removed
            # path can still occupy the same H:C:I:L locally with its old
            # WWID, preventing the new device from being discovered.
            if (!$resize && defined($expected_wwid)) {
                my @blocks = glob("$scsi_device/block/*");
                for my $block (@blocks) {
                    next if $block !~ m|/([^/]+)$|;
                    my $dev = $1;
                    my $current_wwid = $zfsmp_block_wwid->($dev);
                    next if !defined($current_wwid) || $current_wwid eq lc($expected_wwid);
                    my $errors = $zfsmp_delete_path_devices->($dev);
                    die "unable to remove stale path at $host:$channel:$id:$lun: "
                        . join('; ', @$errors) . "\n" if @$errors;
                }
            }

            if ($resize && -w $rescan) {
                $write_sysfs->($rescan, "1\n");
            } else {
                $write_sysfs->($scan, "$channel $id $lun\n");
            }
            $matched++;
        }
    }
    die "no local iSCSI sessions found for target '$target'\n" if !$matched;
    return $matched;
};

# --- storage/volume activation ------------------------------------------------

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache //= {};
    return 1 if $cache->{"zfsiscsimp_active_$storeid"};
    $validate_config->($scfg);

    for my $binary ($ISCSIADM, $MULTIPATH, $MULTIPATHD) {
        die "required executable '$binary' is missing\n" if !-x $binary;
    }

    my $rc = eval {
        run_command(['systemctl', 'is-active', '--quiet', 'multipathd'], noerr => 1, quiet => 1);
    };
    die "multipathd is not active on this node - install/enable multipath-tools\n"
        if !defined($rc) || $rc != 0;

    # keep any remote-pool self-healing the parent may add in future
    $class->SUPER::activate_storage($storeid, $scfg, $cache);

    $zfsmp_login_all->($storeid, $scfg);
    $cache->{"zfsiscsimp_active_$storeid"} = 1;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to activate snapshot from remote zfs storage\n" if $snapname;

    my $name = ($class->parse_volname($volname))[1];

    $validate_config->($scfg);
    $zfsmp_login_all->($storeid, $scfg);

    my $identity = $zfsmp_get_identity->($scfg, $name);
    my $wwid = $identity->{wwid};
    my $add_rc = run_command([$MULTIPATH, '-a', $wwid], noerr => 1, quiet => 1);
    die "unable to add WWID '$wwid' to the multipath WWIDs file (rc=$add_rc)\n"
        if !defined($add_rc) || $add_rc != 0;

    my $mapdev = $zfsmp_mapdev->($wwid);
    my $want = scalar($all_portals->($scfg));
    my $current_paths = $mapdev ? $zfsmp_path_count->($wwid) : 0;
    $zfsmp_rescan_lun->($scfg->{target}, $identity->{lun}, 0, $wwid)
        if !$mapdev || $current_paths < $want;

    for my $try (1 .. 40) {
        $mapdev = $zfsmp_mapdev->($wwid);
        last if $mapdev;
        # multipathd occasionally misses uevents right after a login/scan
        if ($try == 4 || $try == 12 || $try == 24) {
            eval { run_command([$MULTIPATH, $wwid], noerr => 1, quiet => 1) };
        }
        usleep(500_000);
    }
    die "multipath device for wwid '$wwid' did not appear\n" if !$mapdev;

    my $have = 0;
    for my $try (1 .. 20) {
        $have = $zfsmp_path_count->($wwid);
        last if $have >= $want;
        # A session can become operational just after the first sysfs scan.
        # Rescan this LUN (not the whole session) while waiting for redundancy.
        if ($try == 4 || $try == 10 || $try == 16) {
            eval { $zfsmp_rescan_lun->($scfg->{target}, $identity->{lun}, 0, $wwid) };
            warn "zfsiscsimp: retry scan for '$name' failed: $@" if $@;
        }
        usleep(500_000);
    }
    die "multipath map '$wwid' has no usable paths\n" if !$have;
    warn "zfsiscsimp: volume '$name' active on $have/$want paths (reduced redundancy)\n"
        if $have < $want;

    return 1;
}

# teardown outcomes: 1 = torn down (or nothing to tear down), 0 = map still
# in use (flush failed) so the caller must abort a destructive operation.
my $zfsmp_teardown = sub {
    my ($scfg, $name) = @_;

    my $resolved = $zfsmp_resolve_identity->($scfg, $name);
    my $identity;
    if ($resolved->{status} eq 'absent') {
        # A successful saveconfig read definitively proved the backstore is
        # gone. If an old identity is cached, use it to remove any local stale
        # map; otherwise there is no target object or local identity to clean.
        $identity = $resolved->{cached_identity};
        if (!defined($identity)) {
            warn "zfsiscsimp: '$name' has no LIO backstore; nothing to tear down\n";
            return 1;
        }
        warn "zfsiscsimp: '$name' has no LIO backstore; cleaning cached local identity\n";
    } elsif ($resolved->{status} ne 'ok') {
        # A target outage or malformed saveconfig is not proof of absence.
        # Abort before a destructive caller can mistake uncertainty for a
        # successfully completed teardown.
        die "refusing to tear down '$name': identity state is unknown: $resolved->{error}\n";
    } else {
        $identity = $resolved->{identity};
    }
    my $wwid = $identity->{wwid};

    my $mapdev = $zfsmp_mapdev->($wwid);

    # Collect both map slaves and matching raw paths. Inactive LUNs have no
    # dm map, but their SCSI devices must still be removed before LIO can
    # safely reuse the numeric LUN.
    my %paths = map { $_ => 1 } $zfsmp_path_devices->($wwid);
    my $dm = defined($mapdev) ? (readlink($mapdev) // '') : '';
    if (defined($mapdev) && $dm =~ m|(dm-\d+)$|) {
        $paths{$_} = 1 for map { m|([^/]+)$| ? $1 : () } glob("/sys/block/$1/slaves/*");
    }

    if (defined($mapdev)) {
        # Retry with backoff: on live-migration cleanup the just-exited QEMU and
        # udev can hold the map for a couple of seconds. A genuinely in-use map
        # (running VM) keeps failing and we correctly give up after the window.
        my $flushed = 0;
        my $waited = 0;
        for my $try (1 .. 30) {
            my $rc = eval { run_command([$MULTIPATH, '-f', $wwid], noerr => 1, quiet => 1) };
            if ((defined($rc) && $rc == 0) || !$zfsmp_mapdev->($wwid)) {
                $flushed = 1;
                last;
            }
            my $sleep = $try < 6 ? 300_000 : 600_000; # ~1.5s fast, then ~15s total
            usleep($sleep);
            $waited += $sleep;
        }
        # Do not rip out the paths from under a map still in use.
        return 0 if !$flushed;
    }

    # With find_multipaths=strict, removing the WWID prevents future uevents
    # from recreating a map until activate_volume explicitly adds it again.
    my $forget_rc = run_command([$MULTIPATH, '-w', $wwid], noerr => 1, quiet => 1);
    return 0 if !defined($forget_rc) || $forget_rc != 0;

    my $delete_errors = $zfsmp_delete_path_devices->(keys(%paths));
    if (@$delete_errors) {
        warn "zfsiscsimp: incomplete path cleanup for '$name': "
            . join('; ', @$delete_errors) . "\n";
        return 0;
    }

    $zfsmp_forget_wwid->($scfg, $name);
    return 1;
};

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to deactivate snapshot from remote zfs storage\n" if $snapname;

    my $name = ($class->parse_volname($volname))[1];
    my $ok = $zfsmp_teardown->($scfg, $name);
    die "unable to deactivate '$volname': multipath teardown did not complete\n" if !$ok;

    return 1;
}

# drop the local multipath state before the LUN and zvol go away, so no
# stale paths with dangling I/O errors are left behind on the node
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $name = ($class->parse_volname($volname))[1];
    my $ok = $zfsmp_teardown->($scfg, $name);
    die "refusing to free '$volname': multipath map still in use, could not flush\n"
        if defined($ok) && !$ok;

    return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    my $oldname = ($class->parse_volname($volname))[1];
    die "refusing to create base '$volname': multipath teardown did not complete\n"
        if !$zfsmp_teardown->($scfg, $oldname);

    my $newvolname = eval { $class->SUPER::create_base($storeid, $scfg, $volname) };
    my $err = $@;
    $zfsmp_forget_wwid->($scfg, $oldname);
    die $err if $err;
    my $newname = ($class->parse_volname($newvolname))[1];
    $zfsmp_forget_wwid->($scfg, $newname);
    return $newvolname;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $name = ($class->parse_volname($volname))[1];
    die "refusing to roll back '$volname': multipath teardown did not complete\n"
        if !$zfsmp_teardown->($scfg, $name);

    my $result = eval { $class->SUPER::volume_snapshot_rollback($scfg, $storeid, $volname, $snap) };
    my $err = $@;
    $zfsmp_forget_wwid->($scfg, $name);
    die $err if $err;
    return $result;
}

# --- paths handed to QEMU ------------------------------------------------------

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "direct access to snapshots not implemented\n" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $wwid = $zfsmp_get_wwid->($scfg, $name);

    # prefer the live map device; fall back to the stable by-id name so a
    # config read succeeds even before activation
    my $mapdev = $zfsmp_mapdev->($wwid) // "/dev/disk/by-id/dm-uuid-mpath-$wwid";

    return ($mapdev, $vmid, $vtype);
}

sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;

    # path() returns a block device; the generic implementation maps that to
    # a 'host_device' blockdev. Bypass ZFSPlugin's libiscsi variant.
    return PVE::Storage::Plugin::qemu_blockdev_options(
        $class, $scfg, $storeid, $volname, $machine_version, $options,
    );
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    my $name = ($class->parse_volname($volname))[1];

    my $new_size = $class->SUPER::volume_resize($scfg, $storeid, $volname, $size, $running, $snapname);

    my $identity = $zfsmp_get_identity->($scfg, $name);
    my $mapdev = $zfsmp_mapdev->($identity->{wwid});
    return $new_size if !defined($mapdev); # the next activation sees the new size

    # Propagate the new size through each path and verify the final dm size.
    $zfsmp_rescan_lun->($scfg->{target}, $identity->{lun}, 1, $identity->{wwid});
    my $resized = 0;
    for (1 .. 10) {
        my $rc = run_command(
            [$MULTIPATHD, 'resize', 'map', $identity->{wwid}],
            noerr => 1,
            quiet => 1,
        );
        if (defined($rc) && $rc == 0) {
            $resized = 1;
            last;
        }
        usleep(300_000);
    }
    die "zvol '$name' was resized, but multipathd could not resize map '$identity->{wwid}'\n"
        if !$resized;

    my $actual = '';
    my $size_rc = run_command(
        [$BLOCKDEV, '--getsize64', $mapdev],
        noerr => 1,
        quiet => 1,
        outfunc => sub { $actual .= $_[0] },
    );
    my $expected = $new_size * 1024;
    die "zvol '$name' was resized, but map size verification failed (rc=$size_rc, "
        . "actual='$actual', expected='$expected')\n"
        if !defined($size_rc) || $size_rc != 0 || $actual !~ /^\d+$/ || $actual != $expected;

    return $new_size;
}

1;
