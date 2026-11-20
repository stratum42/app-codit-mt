package App::Codit::MT::Plugins::FileBrowser;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

use File::Spec ();

our $VERSION = '0.01';

my %SKIP_DIRS = map { $_ => 1 } qw(.git blib node_modules .svn _build .hg);

=head1 NAME

App::Codit::MT::Plugins::FileBrowser - Workspace file explorer plugin

=head1 SYNOPSIS

    my $fb = App::Codit::MT::Plugins::FileBrowser->new();
    $fb->init($app);

=head1 DESCRIPTION

Adds a left-dock C<ttk::treeview> workspace explorer to L<App::Codit::MT> with
lazy directory expansion, incremental filename filtering, and double-click or
Enter to open files in an MDI tab.

=cut

sub name { 'FileBrowser' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{root}        = $app->workspace // '.';
    $self->{node_path}   = {};
    $self->{node_is_dir} = {};
    $self->{populated}   = {};
    $self->{filter_text} = '';
    $self->{filter_job}  = undef;
    $self->{seq}         = 0;

    return if $app->headless || !$app->left_dock;

    my $dock  = $app->left_dock;
    my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
    $self->{frame} = $frame;

    # Top filter bar
    my $bar = $frame->ttkFrame(-style => 'Dark.TFrame');
    $bar->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => 4);

    my $entry = $bar->ttkEntry(
        -style        => 'Dark.TEntry',
        -textvariable => \$self->{filter_text},
    );
    $entry->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => [0, 4]);
    $self->{filter_entry} = $entry;

    my $refresh_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Reload',
        -width   => 6,
        -command => sub { $self->refresh() },
    );
    $refresh_btn->pack(-side => 'right');

    # Treeview + vertical scrollbar
    my $tree_wrap = $frame->ttkFrame(-style => 'Dark.TFrame');
    $tree_wrap->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 4, -pady => [0, 4]);

    my $tree = $tree_wrap->ttkTreeview(
        -style      => 'Dark.Treeview',
        -show       => 'tree',
        -selectmode => 'browse',
    );
    my $vsb = $tree_wrap->ttkScrollbar(
        -style   => 'Dark.Vertical.TScrollbar',
        -orient  => 'vertical',
        -command => "$tree yview",
    );
    $tree->configure(-yscrollcommand => "$vsb set");

    $vsb->pack(-side => 'right', -fill => 'y');
    $tree->pack(-side => 'left', -fill => 'both', -expand => 1);
    $self->{tree} = $tree;

    $tree->bind('<<TreeviewOpen>>', sub { $self->_on_tree_open() });
    $tree->bind('<Double-1>',       sub { $self->_on_activate() });
    $tree->bind('<Return>',         sub { $self->_on_activate() });

    $entry->bind('<KeyRelease>', sub { $self->_schedule_filter() });
    $entry->bind('<Return>',     sub { $self->refresh() });

    $app->add_left_tab('Files', $frame);
    $self->refresh();

    return $self;
}

sub set_root {
    my ($self, $dir) = @_;
    return unless defined $dir && -d $dir;
    $self->{root} = $dir;
    $self->refresh();
}

sub root { $_[0]{root} }

sub _schedule_filter {
    my ($self) = @_;
    my $app = $self->app or return;
    if (defined $self->{filter_job}) {
        $app->after_cancel($self->{filter_job});
        $self->{filter_job} = undef;
    }
    $self->{filter_job} = $app->after(180, sub {
        $self->{filter_job} = undef;
        $self->refresh();
    });
}

sub list_entries {
    my ($self, $dir) = @_;
    return ([], []) unless defined $dir && -d $dir;

    opendir(my $dh, $dir) or return ([], []);
    my (@dirs, @files);
    while (defined(my $ent = readdir($dh))) {
        next if $ent eq '.' || $ent eq '..';
        next if $SKIP_DIRS{$ent};
        next if $ent eq '.DS_Store';
        my $full = File::Spec->catfile($dir, $ent);
        if (-d $full) {
            push @dirs, [ $ent, $full ];
        }
        else {
            push @files, [ $ent, $full ];
        }
    }
    closedir($dh);

    @dirs  = sort { lc($a->[0]) cmp lc($b->[0]) } @dirs;
    @files = sort { lc($a->[0]) cmp lc($b->[0]) } @files;
    return (\@dirs, \@files);
}

sub refresh {
    my ($self) = @_;
    my $tree = $self->{tree} or return;

    # Clear existing root children
    my @kids = $self->_tree_children('');
    $tree->delete(@kids) if @kids;

    $self->{node_path}   = {};
    $self->{node_is_dir} = {};
    $self->{populated}   = {};

    my $root = $self->{root};
    return unless defined $root && -d $root;

    my $filter = defined($self->{filter_text}) ? $self->{filter_text} : '';
    $filter =~ s/\A\s+|\s+\z//g;

    if (length $filter) {
        $self->_populate_filtered($root, $filter);
    }
    else {
        $self->_populate_dir('', $root);
    }
}

sub _populate_dir {
    my ($self, $parent_id, $dir) = @_;
    my $tree = $self->{tree} or return;

    my ($dirs, $files) = $self->list_entries($dir);

    for my $d (@$dirs) {
        my ($name, $full) = @$d;
        my $id = 'fb_' . (++$self->{seq});
        $tree->insert($parent_id, 'end', -id => $id, -text => "$name/");
        $self->{node_path}{$id}   = $full;
        $self->{node_is_dir}{$id} = 1;
        # Placeholder child for lazy expansion
        my $dummy = "dummy_$id";
        $tree->insert($id, 'end', -id => $dummy, -text => '');
    }

    for my $f (@$files) {
        my ($name, $full) = @$f;
        my $id = 'fb_' . (++$self->{seq});
        $tree->insert($parent_id, 'end', -id => $id, -text => $name);
        $self->{node_path}{$id}   = $full;
        $self->{node_is_dir}{$id} = 0;
    }

    $self->{populated}{$parent_id} = 1 if length $parent_id;
}

sub _populate_filtered {
    my ($self, $root, $filter) = @_;
    my $tree = $self->{tree} or return;

    my $needle = lc($filter);
    my $limit  = 400;
    my $count  = 0;
    my @queue  = ([ $root, '' ]);

    while (@queue && $count < $limit) {
        my $item = shift @queue;
        my ($dir, $rel_prefix) = @$item;
        my ($dirs, $files) = $self->list_entries($dir);

        for my $f (@$files) {
            my ($name, $full) = @$f;
            my $rel = length($rel_prefix) ? "$rel_prefix/$name" : $name;
            if (index(lc($rel), $needle) >= 0) {
                my $id = 'fb_' . (++$self->{seq});
                $tree->insert('', 'end', -id => $id, -text => $rel);
                $self->{node_path}{$id}   = $full;
                $self->{node_is_dir}{$id} = 0;
                $count++;
                last if $count >= $limit;
            }
        }
        for my $d (@$dirs) {
            my ($name, $full) = @$d;
            my $rel = length($rel_prefix) ? "$rel_prefix/$name" : $name;
            push @queue, [ $full, $rel ];
        }
    }
}

sub _on_tree_open {
    my ($self) = @_;
    my $tree = $self->{tree} or return;
    my $id   = eval { $tree->focus() };
    return unless defined $id && length $id;
    return if $self->{populated}{$id};
    return unless $self->{node_is_dir}{$id};

    my $dir = $self->{node_path}{$id};
    return unless defined $dir && -d $dir;

    my @kids = $self->_tree_children($id);
    $tree->delete(@kids) if @kids;
    $self->_populate_dir($id, $dir);
}

sub _on_activate {
    my ($self) = @_;
    my $app  = $self->app  or return;
    my $tree = $self->{tree} or return;

    my $id = $self->_selected_id();
    return unless defined $id && length $id;

    if ($self->{node_is_dir}{$id}) {
        my $is_open = eval { $tree->item($id, '-open') } ? 1 : 0;
        $tree->item($id, -open => $is_open ? 0 : 1);
        $self->_on_tree_open() unless $is_open;
        return;
    }

    my $path = $self->{node_path}{$id};
    if (defined $path && -f $path) {
        $app->open_file($path);
    }
}

sub _selected_id {
    my ($self) = @_;
    my $tree = $self->{tree} or return undef;
    my @sel = $tree->selection();
    if (@sel == 1 && defined $sel[0] && $sel[0] =~ /\s/) {
        @sel = split /\s+/, $sel[0];
    }
    return $sel[0] if @sel && defined $sel[0] && length $sel[0];
    my $foc = eval { $tree->focus() };
    return (defined $foc && length $foc) ? $foc : undef;
}

sub _tree_children {
    my ($self, $parent_id) = @_;
    my $tree = $self->{tree} or return ();
    my @raw = eval { $tree->children($parent_id) };
    if (@raw == 1 && defined $raw[0] && $raw[0] =~ /\s/) {
        @raw = split /\s+/, $raw[0];
    }
    return grep { defined $_ && length $_ } @raw;
}

sub shutdown {
    my ($self) = @_;
    my $app = $self->app;
    if ($app && defined $self->{filter_job}) {
        $app->after_cancel($self->{filter_job});
        $self->{filter_job} = undef;
    }
}

1;
