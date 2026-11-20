package App::Codit::MT::Plugins::Bookmarks;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugins::Bookmarks - Line bookmarks plugin with gutter markers

=head1 SYNOPSIS

    my $bm = App::Codit::MT::Plugins::Bookmarks->new();
    $bm->init($app);
    $bm->toggle_current();

=head1 DESCRIPTION

Adds a left-dock Bookmarks panel to L<App::Codit::MT> supporting line bookmark
toggling (C<Cmd/Ctrl+B> or toolbar button), gutter markers on each
L<App::Codit::MT::Document>, and click-to-jump navigation across all open
documents.

=cut

sub name { 'Bookmarks' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{node_ref} = {};
    $self->{seq}      = 0;

    return if $app->headless || !$app->left_dock;

    my $dock  = $app->left_dock;
    my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
    $self->{frame} = $frame;

    my $bar = $frame->ttkFrame(-style => 'Dark.TFrame');
    $bar->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => 4);

    my $toggle_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Toggle (Ctrl+B)',
        -command => sub { $self->toggle_current() },
    );
    $toggle_btn->pack(-side => 'left', -padx => [0, 4]);

    my $clear_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Clear',
        -width   => 6,
        -command => sub { $self->clear_current_doc() },
    );
    $clear_btn->pack(-side => 'right');

    my $wrap = $frame->ttkFrame(-style => 'Dark.TFrame');
    $wrap->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 4, -pady => [0, 4]);

    my $tree = $wrap->ttkTreeview(
        -style      => 'Dark.Treeview',
        -show       => 'tree',
        -selectmode => 'browse',
    );
    my $vsb = $wrap->ttkScrollbar(
        -style   => 'Dark.Vertical.TScrollbar',
        -orient  => 'vertical',
        -command => "$tree yview",
    );
    $tree->configure(-yscrollcommand => "$vsb set");

    $vsb->pack(-side => 'right', -fill => 'y');
    $tree->pack(-side => 'left', -fill => 'both', -expand => 1);
    $self->{tree} = $tree;

    $tree->bind('<<TreeviewSelect>>', sub { $self->_on_select() });
    $tree->bind('<Double-1>',         sub { $self->_on_select() });
    $tree->bind('<Return>',           sub { $self->_on_select() });

    $app->add_left_tab('Bookmarks', $frame);
    $self->refresh();
    return $self;
}

sub toggle {
    my ($self, $doc, $line) = @_;
    return 0 unless $doc;
    $line = $doc->cursor_line() unless defined $line;
    my $state = $doc->toggle_bookmark($line);
    $self->refresh();
    if (my $app = $self->app) {
        $app->redraw_active();
    }
    return $state;
}

sub toggle_current {
    my ($self) = @_;
    my $app = $self->app or return 0;
    my $doc = $app->active_doc or return 0;
    return $self->toggle($doc, $doc->cursor_line());
}

sub clear_current_doc {
    my ($self) = @_;
    my $app = $self->app or return;
    my $doc = $app->active_doc or return;
    $doc->clear_bookmarks();
    $self->refresh();
    $app->redraw_active();
}

sub list_bookmarks {
    my ($self) = @_;
    my $app  = $self->app or return [];
    my $docs = $app->open_documents() || [];
    my @out;

    for my $doc (@$docs) {
        my $bms = $doc->bookmarks() || {};
        for my $line (sort { $a <=> $b } keys %$bms) {
            next unless $bms->{$line};
            my $preview = $doc->get_line($line);
            $preview = '' unless defined $preview;
            $preview =~ s/\A\s+//;
            $preview = substr($preview, 0, 60) if length($preview) > 60;
            push @out, {
                doc     => $doc,
                title   => $doc->title || 'untitled',
                path    => $doc->path,
                line    => $line,
                preview => $preview,
            };
        }
    }
    return \@out;
}

sub refresh {
    my ($self) = @_;
    my $tree = $self->{tree} or return;

    my @kids = $self->_tree_children('');
    $tree->delete(@kids) if @kids;
    $self->{node_ref} = {};

    my $items = $self->list_bookmarks();
    for my $bm (@$items) {
        my $id    = 'bm_' . (++$self->{seq});
        my $line1 = $bm->{line} + 1;
        my $label = "$bm->{title}:$line1  $bm->{preview}";
        $tree->insert('', 'end', -id => $id, -text => $label);
        $self->{node_ref}{$id} = $bm;
    }
}

sub _on_select {
    my ($self) = @_;
    my $app  = $self->app  or return;
    my $tree = $self->{tree} or return;

    my @sel = $tree->selection();
    if (@sel == 1 && defined $sel[0] && $sel[0] =~ /\s/) {
        @sel = split /\s+/, $sel[0];
    }
    my $id = $sel[0] or return;
    my $bm = $self->{node_ref}{$id} or return;

    if ($bm->{doc}) {
        $app->switch_to_doc($bm->{doc});
        $app->goto_line($bm->{line}, 0);
    }
    elsif (defined $bm->{path} && length $bm->{path}) {
        $app->open_file($bm->{path}, line => $bm->{line}, col => 0);
    }
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

sub on_doc_open   { $_[0]->refresh() }
sub on_doc_switch { $_[0]->refresh() }
sub on_doc_close  { $_[0]->refresh() }

1;
