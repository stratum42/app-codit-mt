package App::Codit::MT::Plugins::PerlSubs;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

our $VERSION = '0.01';

my %C_CONTROL = map { $_ => 1 } qw(if for while switch catch sizeof return else do);

=head1 NAME

App::Codit::MT::Plugins::PerlSubs - Code outline plugin for Perl and C/XS files

=head1 SYNOPSIS

    my $outline = App::Codit::MT::Plugins::PerlSubs->new();
    $outline->init($app);

=head1 DESCRIPTION

Adds a left-dock C<ttk::treeview> symbol outline to L<App::Codit::MT> that
extracts Perl C<package> and C<sub> declarations as well as C/XS function
definitions from the active document, updating on open, tab switch, and save
with click-to-jump navigation.

=cut

sub name { 'PerlSubs' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{node_line} = {};
    $self->{symbols}   = [];
    $self->{seq}       = 0;

    return if $app->headless || !$app->left_dock;

    my $dock  = $app->left_dock;
    my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
    $self->{frame} = $frame;

    my $bar = $frame->ttkFrame(-style => 'Dark.TFrame');
    $bar->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => 4);

    $bar->ttkLabel(-style => 'Dark.TLabel', -text => 'Outline')->pack(-side => 'left');
    my $btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Refresh',
        -width   => 7,
        -command => sub { $self->refresh() },
    );
    $btn->pack(-side => 'right');

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

    $app->add_left_tab('Outline', $frame);
    return $self;
}

sub symbols { $_[0]{symbols} }

sub extract_symbols {
    my ($self, $doc, %opts) = @_;
    return [] unless $doc;

    my $lang = $doc->can('language') ? ($doc->language // 'text') : 'text';
    my $path = $doc->can('path')     ? ($doc->path     // '')     : '';

    my $mode = 'perl';
    if ($lang eq 'c' || $path =~ /\.(?:c|h|xs|cc|cpp|hpp)\z/i) {
        $mode = 'c';
    }
    elsif ($lang eq 'perl' || $path =~ /\.(?:pl|pm|t|psgi)\z/i) {
        $mode = 'perl';
    }
    else {
        $mode = 'perl';
    }

    my $total     = $doc->line_count();
    my $max_lines = $opts{max_lines} || 20000;
    my $max_syms  = $opts{max_syms}  || 1500;
    my $scan_end  = ($total < $max_lines) ? $total : $max_lines;
    my $chunk     = 4096;

    my @syms;
    my $in_pod = 0;

    for (my $start = 0; $start < $scan_end && @syms < $max_syms; $start += $chunk) {
        my $cnt   = $scan_end - $start;
        $cnt      = $chunk if $cnt > $chunk;
        my $lines = $doc->get_lines($start, $cnt);
        next unless $lines;

        if ($mode eq 'perl') {
            for my $i (0 .. $#$lines) {
                my $l = $lines->[$i];
                if ($l =~ /\A=(?:pod|head[1-4]|over|begin|encoding|item)\b/) {
                    $in_pod = 1;
                    next;
                }
                if ($in_pod) {
                    $in_pod = 0 if $l =~ /\A=cut\b/;
                    next;
                }
                if ($l =~ /\A\s*package\s+([A-Za-z_][A-Za-z0-9_:]*)/) {
                    push @syms, { kind => 'package', name => $1, line => $start + $i };
                }
                elsif ($l =~ /\A\s*(?:my\s+|our\s+)?(?:sub|method)\s+([A-Za-z_][A-Za-z0-9_]*)/) {
                    push @syms, { kind => 'sub', name => $1, line => $start + $i };
                }
                last if @syms >= $max_syms;
            }
        }
        else {
            my $prev_line = '';
            for my $i (0 .. $#$lines) {
                my $l = $lines->[$i];
                if ($l =~ /\AMODULE\s*=\s*(\S+)/) {
                    push @syms, { kind => 'package', name => $1, line => $start + $i };
                }
                elsif ($l =~ /\A(?:[A-Za-z_][A-Za-z0-9_*\s]*\s+\*?)?([A-Za-z_][A-Za-z0-9_]*)\s*\([^;]*\)\s*(?:\{)?\s*\z/) {
                    my $fn = $1;
                    if (!$C_CONTROL{$fn} && $l !~ /\A\s*#/ && ($l =~ /\{\s*\z/ || ($i + 1 <= $#$lines && $lines->[$i + 1] =~ /\A\s*\{/))) {
                        push @syms, { kind => 'func', name => $fn, line => $start + $i };
                    }
                }
                $prev_line = $l;
                last if @syms >= $max_syms;
            }
        }
    }

    return \@syms;
}

sub refresh {
    my ($self, $doc) = @_;
    my $app = $self->app;
    $doc ||= ($app ? $app->active_doc : undef);

    my $syms = $doc ? $self->extract_symbols($doc) : [];
    $self->{symbols} = $syms;

    my $tree = $self->{tree} or return $syms;

    my @kids = $self->_tree_children('');
    $tree->delete(@kids) if @kids;
    $self->{node_line} = {};

    my $cur_pkg_node = '';
    for my $sym (@$syms) {
        my $id    = 'ps_' . (++$self->{seq});
        my $line1 = $sym->{line} + 1;
        if ($sym->{kind} eq 'package') {
            $tree->insert('', 'end', -id => $id, -text => "pkg $sym->{name}  :$line1", -open => 1);
            $self->{node_line}{$id} = $sym->{line};
            $cur_pkg_node = $id;
        }
        else {
            my $prefix = ($sym->{kind} eq 'func') ? 'fn ' : 'sub ';
            $tree->insert($cur_pkg_node, 'end', -id => $id, -text => "$prefix$sym->{name}  :$line1");
            $self->{node_line}{$id} = $sym->{line};
        }
    }

    return $syms;
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
    my $line = $self->{node_line}{$id};
    return unless defined $line;

    $app->goto_line($line, 0);
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

sub on_doc_open   { my ($self, $doc) = @_; $self->refresh($doc); }
sub on_doc_switch { my ($self, $doc) = @_; $self->refresh($doc); }
sub on_doc_save   { my ($self, $doc) = @_; $self->refresh($doc); }

1;
