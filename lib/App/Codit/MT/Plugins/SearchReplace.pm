package App::Codit::MT::Plugins::SearchReplace;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

use File::Spec ();
use App::Codit::MT::Core ();

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugins::SearchReplace - In-file find/replace and multi-threaded project search

=head1 SYNOPSIS

    my $sr = App::Codit::MT::Plugins::SearchReplace->new();
    $sr->init($app);

=head1 DESCRIPTION

Adds a bottom-dock Find/Replace and Project Search panel to L<App::Codit::MT>.
Supports literal, case-insensitive, and regular-expression in-file search with
match highlighting, next/previous navigation, single/all replacement, and
multi-threaded directory search via C<App::Codit::MT::Core::search_dir>.

=cut

sub name { 'SearchReplace' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{find_text}       = '';
    $self->{replace_text}    = '';
    $self->{icase}           = 0;
    $self->{regex}           = 0;
    $self->{status_text}     = 'Ready';
    $self->{doc_matches}     = [];
    $self->{match_idx}       = -1;
    $self->{project_results} = [];
    $self->{row_map}         = {};
    $self->{seq}             = 0;

    return if $app->headless || !$app->bottom_dock;

    my $dock  = $app->bottom_dock;
    my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
    $self->{frame} = $frame;

    # Row 1: Find + Replace controls
    my $row1 = $frame->ttkFrame(-style => 'Dark.TFrame');
    $row1->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => [4, 2]);

    $row1->ttkLabel(-style => 'Dark.TLabel', -text => 'Find:')->pack(-side => 'left', -padx => [0, 4]);
    my $find_ent = $row1->ttkEntry(
        -style        => 'Dark.TEntry',
        -width        => 24,
        -textvariable => \$self->{find_text},
    );
    $find_ent->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => [0, 6]);
    $find_ent->bind('<Return>', sub { $self->find_next() });
    $self->{find_entry} = $find_ent;

    $row1->ttkLabel(-style => 'Dark.TLabel', -text => 'Replace:')->pack(-side => 'left', -padx => [0, 4]);
    my $repl_ent = $row1->ttkEntry(
        -style        => 'Dark.TEntry',
        -width        => 20,
        -textvariable => \$self->{replace_text},
    );
    $repl_ent->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => [0, 6]);
    $repl_ent->bind('<Return>', sub { $self->replace_current() });
    $self->{replace_entry} = $repl_ent;

    my $cb_icase = $row1->ttkCheckbutton(
        -text     => 'Ignore Case',
        -variable => \$self->{icase},
    );
    $cb_icase->pack(-side => 'left', -padx => [0, 6]);

    my $cb_regex = $row1->ttkCheckbutton(
        -text     => 'Regex',
        -variable => \$self->{regex},
    );
    $cb_regex->pack(-side => 'left', -padx => [0, 6]);

    # Row 2: Action buttons + status
    my $row2 = $frame->ttkFrame(-style => 'Dark.TFrame');
    $row2->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => [0, 3]);

    my @buttons = (
        [ 'Find',           sub { $self->find_in_active() } ],
        [ 'Prev',           sub { $self->find_prev() } ],
        [ 'Next',           sub { $self->find_next() } ],
        [ 'Replace',        sub { $self->replace_current() } ],
        [ 'Replace All',    sub { $self->replace_all_in_active() } ],
        [ 'Search Project', sub { $self->search_project_from_entry() } ],
        [ 'Clear',          sub { $self->clear_matches() } ],
    );
    for my $b (@buttons) {
        my $btn = $row2->ttkButton(
            -style   => 'Dark.TButton',
            -text    => $b->[0],
            -command => $b->[1],
        );
        $btn->pack(-side => 'left', -padx => [0, 4]);
    }

    my $st_lbl = $row2->ttkLabel(
        -style        => 'Dark.TLabel',
        -textvariable => \$self->{status_text},
    );
    $st_lbl->pack(-side => 'right', -padx => 4);

    # Row 3: Clickable project/in-file results tree
    my $res_wrap = $frame->ttkFrame(-style => 'Dark.TFrame');
    $res_wrap->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 4, -pady => [0, 4]);

    my $tree = $res_wrap->ttkTreeview(
        -style      => 'Dark.Treeview',
        -show       => 'tree',
        -selectmode => 'browse',
    );
    my $vsb = $res_wrap->ttkScrollbar(
        -style   => 'Dark.Vertical.TScrollbar',
        -orient  => 'vertical',
        -command => "$tree yview",
    );
    $tree->configure(-yscrollcommand => "$vsb set");

    $vsb->pack(-side => 'right', -fill => 'y');
    $tree->pack(-side => 'left', -fill => 'both', -expand => 1);
    $self->{tree} = $tree;

    $tree->bind('<Double-1>',          sub { $self->_jump_selected_result() });
    $tree->bind('<Return>',            sub { $self->_jump_selected_result() });
    $tree->bind('<<TreeviewSelect>>',  sub { $self->_jump_selected_result() });

    $app->add_bottom_tab('Search', $frame);
    return $self;
}

sub focus_find {
    my ($self) = @_;
    my $app = $self->app or return;
    $app->select_bottom_tab($self->{frame}) if $self->{frame};
    if ($self->{find_entry}) {
        eval { $self->{find_entry}->focus() };
    }
}

sub focus_project_search {
    my ($self) = @_;
    $self->focus_find();
}

sub find_in_doc {
    my ($self, $doc, $query, %opts) = @_;
    return [] unless $doc && defined $query && length $query;

    my $icase = exists $opts{icase} ? ($opts{icase} ? 1 : 0) : ($self->{icase} ? 1 : 0);
    my $regex = exists $opts{regex} ? ($opts{regex} ? 1 : 0) : ($self->{regex} ? 1 : 0);
    my $max   = $opts{max_matches} || 10000;

    my $matches;
    if (!$regex) {
        $matches = $doc->search_buffer($query, $icase, $max);
    }
    else {
        $matches = [];
        my $re = eval { $icase ? qr/$query/i : qr/$query/ };
        if ($@ || !defined $re) {
            $self->{status_text} = 'Invalid regex';
            return [];
        }
        my $total = $doc->line_count();
        my $chunk = 4096;
        for (my $start = 0; $start < $total && @$matches < $max; $start += $chunk) {
            my $lines = $doc->get_lines($start, $chunk);
            for my $i (0 .. $#$lines) {
                my $text = $lines->[$i];
                while ($text =~ /$re/g) {
                    my $col = $-[0];
                    my $len = $+[0] - $-[0];
                    if ($len == 0) {
                        pos($text) = $col + 1;
                        last if $col >= length($text);
                        next;
                    }
                    push @$matches, {
                        line    => $start + $i,
                        col     => $col,
                        len     => $len,
                        preview => substr($text, 0, 120),
                    };
                    last if @$matches >= $max;
                }
                last if @$matches >= $max;
            }
        }
        $doc->set_search_matches($matches);
    }

    $self->{doc_matches} = $matches || [];
    $self->{match_idx}   = @$matches ? 0 : -1;
    $self->{status_text} = scalar(@$matches) . ' match' . (@$matches == 1 ? '' : 'es');
    return $matches;
}

sub find_in_active {
    my ($self) = @_;
    my $app = $self->app or return [];
    my $doc = $app->active_doc or return [];
    my $q   = $self->{find_text};
    return [] unless defined $q && length $q;

    my $matches = $self->find_in_doc($doc, $q);
    $self->_populate_doc_results($doc, $matches);
    if (@$matches) {
        $self->_select_match_index(0);
    }
    else {
        $app->redraw_active();
    }
    return $matches;
}

sub find_next {
    my ($self) = @_;
    my $app = $self->app or return;
    my $doc = $app->active_doc or return;
    my $q   = $self->{find_text};
    return unless defined $q && length $q;

    if (!@{ $self->{doc_matches} }) {
        $self->find_in_active();
        return;
    }

    my $n = scalar @{ $self->{doc_matches} };
    return unless $n;
    my $idx = ($self->{match_idx} + 1) % $n;
    $self->_select_match_index($idx);
}

sub find_prev {
    my ($self) = @_;
    my $app = $self->app or return;
    my $doc = $app->active_doc or return;
    my $q   = $self->{find_text};
    return unless defined $q && length $q;

    if (!@{ $self->{doc_matches} }) {
        $self->find_in_active();
        return;
    }

    my $n = scalar @{ $self->{doc_matches} };
    return unless $n;
    my $idx = ($self->{match_idx} <= 0) ? ($n - 1) : ($self->{match_idx} - 1);
    $self->_select_match_index($idx);
}

sub _select_match_index {
    my ($self, $idx) = @_;
    my $app = $self->app or return;
    my $doc = $app->active_doc or return;
    my $matches = $self->{doc_matches};
    return unless $matches && $idx >= 0 && $idx < @$matches;

    $self->{match_idx} = $idx;
    my $m = $matches->[$idx];
    $doc->set_selection($m->{line}, $m->{col}, $m->{line}, $m->{col} + $m->{len});
    $app->goto_line($m->{line}, $m->{col});
    $self->{status_text} = sprintf('Match %d / %d', $idx + 1, scalar(@$matches));
}

sub replace_current {
    my ($self) = @_;
    my $app = $self->app or return 0;
    my $doc = $app->active_doc or return 0;
    my $q   = $self->{find_text};
    return 0 unless defined $q && length $q;

    if (!@{ $self->{doc_matches} } || $self->{match_idx} < 0) {
        $self->find_in_active();
        return 0 unless @{ $self->{doc_matches} };
    }

    my $idx = $self->{match_idx};
    my $m   = $self->{doc_matches}[$idx] or return 0;
    my $rep = defined($self->{replace_text}) ? $self->{replace_text} : '';

    $doc->replace_range($m->{line}, $m->{col}, $m->{line}, $m->{col} + $m->{len}, $rep);

    my $matches = $self->find_in_doc($doc, $q);
    $self->_populate_doc_results($doc, $matches);
    if (@$matches) {
        my $next_idx = ($idx < @$matches) ? $idx : 0;
        $self->_select_match_index($next_idx);
    }
    else {
        $app->redraw_active();
    }
    return 1;
}

sub replace_all {
    my ($self, $doc, $query, $repl, %opts) = @_;
    return 0 unless $doc && defined $query && length $query;
    $repl = '' unless defined $repl;

    my $matches = $self->find_in_doc($doc, $query, %opts);
    return 0 unless @$matches;

    # Apply replacements in reverse order so earlier offsets stay valid
    for my $m (reverse @$matches) {
        $doc->replace_range($m->{line}, $m->{col}, $m->{line}, $m->{col} + $m->{len}, $repl);
    }

    my $count = scalar @$matches;
    $doc->clear_search_matches();
    $self->{doc_matches} = [];
    $self->{match_idx}   = -1;
    $self->{status_text} = "Replaced $count occurrence" . ($count == 1 ? '' : 's');
    return $count;
}

sub replace_all_in_active {
    my ($self) = @_;
    my $app = $self->app or return 0;
    my $doc = $app->active_doc or return 0;
    my $n   = $self->replace_all($doc, $self->{find_text}, $self->{replace_text});
    $self->_clear_tree();
    $app->redraw_active();
    return $n;
}

sub search_project {
    my ($self, $query, %opts) = @_;
    my $app = $self->app;
    return [] unless defined $query && length $query;

    my $root  = $opts{root}  // ($app ? $app->workspace : '.');
    my $icase = exists $opts{icase} ? ($opts{icase} ? 1 : 0) : ($self->{icase} ? 1 : 0);
    my $max   = $opts{max_matches} || 5000;

    my $results = App::Codit::MT::Core::search_dir($root, $query, $icase, $max);
    $self->{project_results} = $results || [];
    $self->{status_text} = sprintf(
        'Project: %d match%s',
        scalar(@$results),
        (@$results == 1 ? '' : 'es'),
    );
    $self->_populate_project_results($root, $results);
    return $results;
}

sub search_project_from_entry {
    my ($self) = @_;
    my $q = $self->{find_text};
    return [] unless defined $q && length $q;
    return $self->search_project($q);
}

sub clear_matches {
    my ($self) = @_;
    my $app = $self->app;
    if ($app && $app->active_doc) {
        $app->active_doc->clear_search_matches();
        $app->redraw_active();
    }
    $self->{doc_matches}     = [];
    $self->{project_results} = [];
    $self->{match_idx}       = -1;
    $self->{status_text}     = 'Cleared';
    $self->_clear_tree();
}

sub _clear_tree {
    my ($self) = @_;
    my $tree = $self->{tree} or return;
    my @kids = $self->_tree_children('');
    $tree->delete(@kids) if @kids;
    $self->{row_map} = {};
}

sub _populate_doc_results {
    my ($self, $doc, $matches) = @_;
    my $tree = $self->{tree} or return;
    $self->_clear_tree();

    my $path = $doc->path;
    my $name = $doc->title || 'untitled';
    my $cap  = 500;
    my $n    = 0;

    for my $m (@$matches) {
        last if ++$n > $cap;
        my $line1   = $m->{line} + 1;
        my $preview = defined($m->{preview}) ? $m->{preview} : '';
        $preview =~ s/\A\s+//;
        my $id = 'sr_' . (++$self->{seq});
        $tree->insert('', 'end', -id => $id, -text => "$name:$line1: $preview");
        $self->{row_map}{$id} = {
            path => $path,
            doc  => $doc,
            line => $m->{line},
            col  => $m->{col},
            len  => $m->{len},
        };
    }
}

sub _populate_project_results {
    my ($self, $root, $results) = @_;
    my $tree = $self->{tree} or return;
    $self->_clear_tree();

    my $cap = 1000;
    my $n   = 0;
    for my $m (@$results) {
        last if ++$n > $cap;
        my $path    = $m->{path};
        my $rel     = defined($root) ? File::Spec->abs2rel($path, $root) : $path;
        my $line1   = $m->{line};
        my $line0   = $line1 > 0 ? $line1 - 1 : 0;
        my $preview = defined($m->{preview}) ? $m->{preview} : '';
        $preview =~ s/\A\s+//;
        my $id = 'sr_' . (++$self->{seq});
        $tree->insert('', 'end', -id => $id, -text => "$rel:$line1: $preview");
        $self->{row_map}{$id} = {
            path => $path,
            line => $line0,
            col  => $m->{col} || 0,
            len  => $m->{len} || 0,
        };
    }
}

sub _jump_selected_result {
    my ($self) = @_;
    my $app  = $self->app  or return;
    my $tree = $self->{tree} or return;

    my @sel = $tree->selection();
    if (@sel == 1 && defined $sel[0] && $sel[0] =~ /\s/) {
        @sel = split /\s+/, $sel[0];
    }
    my $id = $sel[0] or return;
    my $info = $self->{row_map}{$id} or return;

    if (defined $info->{path} && length $info->{path}) {
        my $doc = $app->open_file($info->{path}, line => $info->{line}, col => $info->{col});
        if ($doc && $info->{len}) {
            $doc->set_selection($info->{line}, $info->{col}, $info->{line}, $info->{col} + $info->{len});
            $app->redraw_active();
        }
    }
    elsif ($info->{doc}) {
        $app->switch_to_doc($info->{doc});
        $app->goto_line($info->{line}, $info->{col});
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

sub on_doc_switch {
    my ($self, $doc) = @_;
    $self->{doc_matches} = [];
    $self->{match_idx}   = -1;
}

1;
