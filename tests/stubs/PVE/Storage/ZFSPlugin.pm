package PVE::Storage::ZFSPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

sub zfs_request { return; }
sub on_add_hook { return; }
sub activate_storage { return 1; }
sub free_image { return; }
sub create_base { return; }
sub volume_snapshot_rollback { return; }
sub volume_resize { return; }

1;
