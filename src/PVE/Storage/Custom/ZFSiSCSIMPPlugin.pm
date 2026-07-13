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

use JSON qw(decode_json);
use Time::HiRes qw(usleep);

use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;
use PVE::Storage::ZFSPlugin;

use base qw(PVE::Storage::ZFSPlugin);

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

my @ssh_opts = ('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';

my $ISCSIADM = '/usr/bin/iscsiadm';
my $MULTIPATH = '/sbin/multipath';
my $MULTIPATHD = '/sbin/multipathd';

sub type { return 'zfsiscsimp'; }

sub plugindata {
    return {
        content => [{ images => 1 }, { images => 1 }],
        'sensitive-properties' => {},
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
    };
}

sub options {
    return {
        nodes => { optional => 1 },
        disable => { optional => 1 },
        shared => { optional => 1 },
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
        lio_tpg => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
        'zfs-base-path' => { optional => 1 },
    };
}

# host and (optional) port of a portal entry; the iSCSI default port is 3260
my $split_portal = sub {
    my ($entry) = @_;
    # IPv6 in brackets: [::1]:3260
    if ($entry =~ m/^\[(.+)\]:(\d+)$/) {
        return ($1, $2);
    } elsif ($entry =~ m/^\[(.+)\]$/) {
        return ($1, 3260);
    } elsif ($entry =~ m/^(.+):(\d+)$/ && $entry !~ m/:.*:/) {
        # host:port, but not a bare IPv6 literal (which has multiple colons)
        return ($1, $2);
    }
    return ($entry, 3260);
};

my $all_portals = sub {
    my ($scfg) = @_;
    my @portals = ($scfg->{portal});
    push @portals, split(/[,;\s]+/, $scfg->{extraportals} // '');
    return grep { defined($_) && length($_) } @portals;
};

# --- WWID of the LIO backstore backing a volume -----------------------------
#
# LunCmd::LIO names backstores '<pool with / replaced by -> + - + <volname>'
# and lets LIO generate the unit serial. dm-multipath names a LIO LUN by the
# id /lib/udev/scsi_id returns: '3' (NAA type) + '6001405' (NAA header + LIO
# IEEE OUI 0x001405) + the first 25 hex digits of the unit serial. We read the
# serial from storage_objects[].wwn in the target's saveconfig.json, which
# LunCmd::LIO rewrites (targetcli saveconfig) after every LUN change.

my $wwid_cache = {};
my $WWID_CACHE_TTL = 15;

my $read_saveconfig = sub {
    my ($scfg) = @_;

    # try every portal so a downed primary portal does not block activation;
    # fall back to the primary portal's key if a per-portal key is absent
    my $primary = $scfg->{portal};
    for my $portal ($all_portals->($scfg)) {
        my ($host) = $split_portal->($portal);
        my $key = "$id_rsa_path/${host}_id_rsa";
        $key = "$id_rsa_path/${primary}_id_rsa" if !-e $key;
        next if !-e $key;

        for my $cfgpath ('/etc/rtslib-fb-target/saveconfig.json', '/etc/target/saveconfig.json') {
            my $out = '';
            my $cmd = [@ssh_cmd, '-i', $key, "root\@$host", 'cat', $cfgpath];
            my $rc = eval {
                run_command(
                    $cmd,
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

my $zfsmp_get_wwid = sub {
    my ($scfg, $volname) = @_;

    my $bsname = $backstore_name->($scfg, $volname);
    my $cachekey = "$scfg->{target}/$bsname";
    my $entry = $wwid_cache->{$cachekey};
    return $entry->[1] if $entry && time() - $entry->[0] < $WWID_CACHE_TTL;

    my $config = $read_saveconfig->($scfg);
    die "unable to read the LIO saveconfig from any portal of '$scfg->{target}'\n"
        if !defined($config);

    my $serial;
    for my $so (@{ $config->{storage_objects} // [] }) {
        next if !defined($so->{name}) || !defined($so->{wwn});
        if ($so->{name} eq $bsname) {
            $serial = $so->{wwn};
            last;
        }
        # legacy backstores created without the pool prefix
        $serial = $so->{wwn} if $so->{name} eq $volname && !defined($serial);
    }
    die "backstore for volume '$volname' not found on target '$scfg->{target}'\n"
        if !defined($serial);

    my $hex = lc($serial);
    $hex =~ s/[^0-9a-f]//g;
    die "unit serial '$serial' of volume '$volname' is too short for a NAA id\n"
        if length($hex) < 25;

    my $wwid = '36001405' . substr($hex, 0, 25);
    $wwid_cache->{$cachekey} = [time(), $wwid];
    return $wwid;
};

my $zfsmp_forget_wwid = sub {
    my ($scfg, $volname) = @_;
    my $bsname = $backstore_name->($scfg, $volname);
    delete $wwid_cache->{"$scfg->{target}/$bsname"};
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

# number of paths currently in the map (for redundancy checks)
my $zfsmp_path_count = sub {
    my ($mapdev) = @_;
    my $dm = readlink($mapdev) // '';
    return 0 if $dm !~ m|(dm-\d+)$|;
    # glob() in scalar context is an iterator, not a count - force list context
    my @slaves = glob("/sys/block/$1/slaves/*");
    return scalar(@slaves);
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
                # tcp: [3] 192.168.34.11:3260,1 iqn.2026-07.ar.ntc:tank (non-flash)
                if ($line =~ m/^\S+\s+\[\d+\]\s+(\S+?):\d+,\S+\s+(\S+)/) {
                    $sessions->{"$1|$2"} = 1;
                }
            },
        );
    };
    return $sessions;
};

my $zfsmp_login_all = sub {
    my ($scfg) = @_;

    my $target = $scfg->{target};
    my $sessions = $iscsi_sessions->();
    my @errors;

    for my $portal ($all_portals->($scfg)) {
        my ($host, $port) = $split_portal->($portal);
        next if $sessions->{"$host|$target"};

        my $pp = "$host:$port";
        eval {
            run_command(
                [$ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $pp],
                noerr => 1, quiet => 1,
            );
            for my $nv (
                ['node.startup', 'manual'],
                # fail paths fast so multipath switches instead of hanging I/O
                ['node.session.timeo.replacement_timeout', '15'],
            ) {
                run_command(
                    [
                        $ISCSIADM, '-m', 'node', '-T', $target, '-p', $pp,
                        '--op', 'update', '-n', $nv->[0], '-v', $nv->[1],
                    ],
                    noerr => 1, quiet => 1,
                );
            }
            my $rc = run_command(
                [$ISCSIADM, '-m', 'node', '-T', $target, '-p', $pp, '--login'],
                noerr => 1, quiet => 1,
            );
            push @errors, "login to $pp failed (rc=$rc)" if defined($rc) && $rc != 0;
        };
        push @errors, "login to $pp failed: $@" if $@;
    }

    warn "zfsiscsimp: iSCSI login issues for target $target: "
        . join('; ', @errors) . "\n"
        if @errors;
};

# --- storage/volume activation ------------------------------------------------

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache //= {};
    return 1 if $cache->{"zfsiscsimp_active_$storeid"};

    my $rc = eval {
        run_command(['systemctl', 'is-active', '--quiet', 'multipathd'], noerr => 1, quiet => 1);
    };
    die "multipathd is not active on this node - install/enable multipath-tools\n"
        if !defined($rc) || $rc != 0;

    # keep any remote-pool self-healing the parent may add in future
    $class->SUPER::activate_storage($storeid, $scfg, $cache);

    $zfsmp_login_all->($scfg);
    $cache->{"zfsiscsimp_active_$storeid"} = 1;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to activate snapshot from remote zfs storage\n" if $snapname;

    my $name = ($class->parse_volname($volname))[1];

    $zfsmp_login_all->($scfg);

    my $wwid = $zfsmp_get_wwid->($scfg, $name);
    my $mapdev = $zfsmp_mapdev->($wwid);
    goto CHECK_PATHS if $mapdev;

    eval { run_command([$ISCSIADM, '-m', 'session', '--rescan'], noerr => 1, quiet => 1) };

    for my $try (1 .. 40) {
        $mapdev = $zfsmp_mapdev->($wwid);
        last if $mapdev;
        # multipathd occasionally misses uevents right after a login/rescan
        if ($try == 8 || $try == 24) {
            eval { run_command([$MULTIPATH, '-a', $wwid], noerr => 1, quiet => 1) };
            eval { run_command([$MULTIPATH, $wwid], noerr => 1, quiet => 1) };
        }
        usleep(500_000);
    }
    die "multipath device for wwid '$wwid' did not appear\n" if !$mapdev;

  CHECK_PATHS:
    my $want = scalar($all_portals->($scfg));
    my $have = $zfsmp_path_count->($mapdev);
    warn "zfsiscsimp: volume '$name' active on $have/$want paths (reduced redundancy)\n"
        if $have < $want;

    return 1;
}

my $zfsmp_teardown = sub {
    my ($scfg, $name) = @_;

    my $wwid = eval { $zfsmp_get_wwid->($scfg, $name) };
    if (!defined($wwid)) {
        $zfsmp_forget_wwid->($scfg, $name);
        return 1;
    }

    my $mapdev = $zfsmp_mapdev->($wwid);
    if (!$mapdev) {
        $zfsmp_forget_wwid->($scfg, $name);
        return 1;
    }

    # collect the path devices before dropping the map
    my @slaves;
    my $dm = readlink($mapdev) // '';
    if ($dm =~ m|(dm-\d+)$|) {
        @slaves = map { m|([^/]+)$| ? $1 : () } glob("/sys/block/$1/slaves/*");
    }

    my $flushed = 0;
    for my $try (1 .. 5) {
        my $rc = eval { run_command([$MULTIPATH, '-f', $wwid], noerr => 1, quiet => 1) };
        if ((defined($rc) && $rc == 0) || !$zfsmp_mapdev->($wwid)) {
            $flushed = 1;
            last;
        }
        usleep(300_000);
    }

    if (!$flushed) {
        # do NOT rip out the paths from under a map still in use
        $zfsmp_forget_wwid->($scfg, $name);
        return 0;
    }

    # drop the wwid from the bindings so a later session rescan does not
    # silently resurrect an idle map for a volume we tore down
    eval { run_command([$MULTIPATH, '-w', $wwid], noerr => 1, quiet => 1) };

    for my $slave (@slaves) {
        next if $slave !~ /^sd[a-z]+$/;
        my $delpath = "/sys/block/$slave/device/delete";
        next if !-w $delpath;
        eval {
            open(my $fh, '>', $delpath) or die "$!\n";
            print $fh "1";
            close($fh);
        };
    }

    $zfsmp_forget_wwid->($scfg, $name);
    return 1;
};

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to deactivate snapshot from remote zfs storage\n" if $snapname;

    my $name = ($class->parse_volname($volname))[1];
    $zfsmp_teardown->($scfg, $name);

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

    # propagate the new size through the initiator and the multipath map
    my $err;
    eval {
        run_command([$ISCSIADM, '-m', 'session', '--rescan'], noerr => 1, quiet => 1);
        my $wwid = $zfsmp_get_wwid->($scfg, $name);
        run_command([$MULTIPATHD, 'resize', 'map', $wwid], noerr => 1, quiet => 1);
    };
    $err = $@;
    warn "zfsiscsimp: zvol resized but multipath map resize failed for '$name': $err\n"
        if $err;

    return $new_size;
}

1;
