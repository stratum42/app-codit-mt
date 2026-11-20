package App::Codit::MT::Document;

use strict;
use warnings;

use File::Basename qw(basename);
use App::Codit::MT::Core ();

our $VERSION = '0.01';

sub _new_from_pt {
    my ($class, $pt, %opts) = @_;

    my $path = $opts{path};
    my $title = $opts{title};
    if (!defined $title || !length $title) {
        $title = (defined $path && length $path) ? basename($path) : 'untitled';
    }

    my $lang = $opts{language};
    if (!defined $lang || !length $lang) {
        my $hint = (defined $path && length $path) ? $path : $title;
        $lang = App::Codit::MT::Core::detect_language($hint // '');
    }

    my $syntax = App::Codit::MT::Core::Syntax->new($lang);

    return bless {
        pt                 => $pt,
        syntax             => $syntax,
        path               => $path,
        title              => $title,
        language           => $lang,
        dirty              => 0,
        _edit_depth        => 0,
        cursor_line        => 0,
        cursor_col         => 0,
        sel_start          => undef,    # [line, col] or undef
        sel_end            => undef,    # [line, col] or undef
        bookmarks          => {},       # { line => 1 }
        git_gutter         => {},       # { line => 'add'|'mod'|'del' }
        search_matches     => [],       # [ { line, col, len, preview }, ... ]
        active_match_index => undef,
        _cb_seq            => 0,
        _on_change         => [],       # [ [id, code], ... ]
        _on_cursor         => [],
        _on_save           => [],
        _undo_lines        => [],       # tracked min edit line for fast syntax invalidation
        _redo_lines        => [],
    }, $class;
}

sub open_file {
    my ($class, $path, %opts) = @_;
    die "Document::open_file requires a file path" unless defined $path && length $path;
    my $pt = App::Codit::MT::Core::PieceTable->open_file($path);
    return $class->_new_from_pt($pt, %opts, path => $path);
}

sub new_empty {
    my ($class, $name, $lang, %opts) = @_;
    my $pt = defined($opts{content})
        ? App::Codit::MT::Core::PieceTable->from_string($opts{content})
        : App::Codit::MT::Core::PieceTable->new();
    return $class->_new_from_pt(
        $pt,
        %opts,
        title    => $name,
        language => $lang,
    );
}

sub from_string {
    my ($class, $content, %opts) = @_;
    my $pt = App::Codit::MT::Core::PieceTable->from_string(defined($content) ? $content : '');
    return $class->_new_from_pt($pt, %opts);
}

# ---------------------------------------------------------------------------
# Core Accessors
# ---------------------------------------------------------------------------

sub piece_table    { $_[0]{pt} }
sub pt             { $_[0]{pt} }
sub syntax         { $_[0]{syntax} }
sub path           { $_[0]{path} }
sub title          { $_[0]{title} }
sub language       { $_[0]{language} }
sub dirty          { $_[0]{dirty} ? 1 : 0 }
sub revision       { $_[0]{pt}->revision() }
sub line_count     { $_[0]{pt}->line_count() }
sub byte_length    { $_[0]{pt}->byte_length() }
sub can_undo       { $_[0]{pt}->can_undo() }
sub can_redo       { $_[0]{pt}->can_redo() }
sub cursor_line    { $_[0]{cursor_line} }
sub cursor_col     { $_[0]{cursor_col} }
sub sel_start      { $_[0]{sel_start} }
sub sel_end        { $_[0]{sel_end} }
sub bookmarks      { $_[0]{bookmarks} }
sub git_gutter     { $_[0]{git_gutter} }
sub search_matches { $_[0]{search_matches} }

sub cursor {
    my ($self) = @_;
    return wantarray
        ? ($self->{cursor_line}, $self->{cursor_col})
        : [ $self->{cursor_line}, $self->{cursor_col} ];
}

sub set_language {
    my ($self, $lang) = @_;
    $lang = 'text' unless defined $lang && length $lang;
    return $self->{language} if $self->{language} eq $lang;
    $self->{language} = $lang;
    $self->{syntax}->set_language($lang);
    $self->_fire_change();
    return $lang;
}

# ---------------------------------------------------------------------------
# Event Listener Registration
# ---------------------------------------------------------------------------

sub _add_cb {
    my ($self, $slot, $cb) = @_;
    return undef unless ref($cb) eq 'CODE';
    my $id = ++$self->{_cb_seq};
    push @{ $self->{$slot} }, [ $id, $cb ];
    return $id;
}

sub _remove_cb {
    my ($self, $slot, $id) = @_;
    return unless defined $id;
    @{ $self->{$slot} } = grep { $_->[0] != $id } @{ $self->{$slot} };
    return;
}

sub on_change  { my ($self, $cb) = @_; return $self->_add_cb('_on_change', $cb) }
sub off_change { my ($self, $id) = @_; return $self->_remove_cb('_on_change', $id) }

sub on_cursor  { my ($self, $cb) = @_; return $self->_add_cb('_on_cursor', $cb) }
sub off_cursor { my ($self, $id) = @_; return $self->_remove_cb('_on_cursor', $id) }

sub on_save    { my ($self, $cb) = @_; return $self->_add_cb('_on_save', $cb) }
sub off_save   { my ($self, $id) = @_; return $self->_remove_cb('_on_save', $id) }

sub _fire_change {
    my ($self) = @_;
    for my $entry (@{ $self->{_on_change} }) {
        $entry->[1]->($self);
    }
    return;
}

sub _fire_cursor {
    my ($self) = @_;
    my ($line, $col) = ($self->{cursor_line}, $self->{cursor_col});
    for my $entry (@{ $self->{_on_cursor} }) {
        $entry->[1]->($line, $col, $self);
    }
    return;
}

sub _fire_save {
    my ($self) = @_;
    for my $entry (@{ $self->{_on_save} }) {
        $entry->[1]->($self);
    }
    return;
}

# ---------------------------------------------------------------------------
# Text & Syntax Queries
# ---------------------------------------------------------------------------

sub get_line {
    my ($self, $line) = @_;
    return undef if !defined($line) || $line < 0;
    return $self->{pt}->get_line($line);
}

sub get_lines {
    my ($self, $start, $count) = @_;
    $start = 0 if !defined($start) || $start < 0;
    $count = 0 if !defined($count) || $count < 0;
    return [] if $count == 0;
    return $self->{pt}->get_lines($start, $count);
}

sub to_string {
    my ($self) = @_;
    return $self->{pt}->to_string();
}

sub tokenize_range {
    my ($self, $first_line, $count) = @_;
    $first_line = 0 if !defined($first_line) || $first_line < 0;
    $count      = 0 if !defined($count)      || $count < 0;
    return [] if $count == 0;
    return $self->{syntax}->tokenize_range($self->{pt}, $first_line, $count);
}

# ---------------------------------------------------------------------------
# Cursor & Selection
# ---------------------------------------------------------------------------

sub _clamp_line_col {
    my ($self, $line, $col) = @_;
    my $lc = $self->{pt}->line_count();
    my $max_line = $lc > 0 ? $lc - 1 : 0;
    $line = int($line // 0);
    $line = 0         if $line < 0;
    $line = $max_line if $line > $max_line;

    my $text = $self->{pt}->get_line($line);
    my $len  = defined($text) ? length($text) : 0;
    $col = int($col // 0);
    $col = 0    if $col < 0;
    $col = $len if $col > $len;
    return ($line, $col);
}

sub goto_line {
    my ($self, $line, $col, %opts) = @_;
    ($line, $col) = $self->_clamp_line_col($line, $col // 0);
    $self->{cursor_line} = $line;
    $self->{cursor_col}  = $col;
    if (!$opts{keep_selection}) {
        $self->{sel_start} = undef;
        $self->{sel_end}   = undef;
    }
    $self->_fire_cursor();
    return ($line, $col);
}

sub has_selection {
    my ($self) = @_;
    return 0 unless defined $self->{sel_start} && defined $self->{sel_end};
    my ($sl, $sc) = @{ $self->{sel_start} };
    my ($el, $ec) = @{ $self->{sel_end} };
    return ($sl != $el || $sc != $ec) ? 1 : 0;
}

sub set_selection {
    my ($self, $sl, $sc, $el, $ec) = @_;
    ($sl, $sc) = $self->_clamp_line_col($sl, $sc);
    ($el, $ec) = $self->_clamp_line_col($el, $ec);
    $self->{sel_start}   = [ $sl, $sc ];
    $self->{sel_end}     = [ $el, $ec ];
    $self->{cursor_line} = $el;
    $self->{cursor_col}  = $ec;
    $self->_fire_cursor();
    return;
}

sub clear_selection {
    my ($self) = @_;
    $self->{sel_start} = undef;
    $self->{sel_end}   = undef;
    return;
}

sub selection_bounds {
    my ($self) = @_;
    return undef unless $self->has_selection();
    my ($sl, $sc) = @{ $self->{sel_start} };
    my ($el, $ec) = @{ $self->{sel_end} };
    if ($sl > $el || ($sl == $el && $sc > $ec)) {
        return [ $el, $ec, $sl, $sc ];
    }
    return [ $sl, $sc, $el, $ec ];
}

sub selected_text {
    my ($self) = @_;
    my $b = $self->selection_bounds() or return '';
    my ($sl, $sc, $el, $ec) = @$b;
    if ($sl == $el) {
        my $line = $self->get_line($sl) // '';
        return substr($line, $sc, $ec - $sc);
    }
    my $lines = $self->get_lines($sl, $el - $sl + 1);
    return '' unless $lines && @$lines;
    $lines->[0]  = substr($lines->[0], $sc);
    $lines->[-1] = substr($lines->[-1], 0, $ec);
    return join("\n", @$lines);
}

# ---------------------------------------------------------------------------
# Editing, Undo/Redo, and Persistence
# ---------------------------------------------------------------------------

sub _byte_len {
    my ($str) = @_;
    use bytes;
    return length($str);
}

sub _record_edit {
    my ($self, $line) = @_;
    push @{ $self->{_undo_lines} }, $line;
    @{ $self->{_redo_lines} } = ();
    if (defined $self->{_edit_depth}) {
        if ($self->{_edit_depth} < 0) {
            # Saved state lived on the discarded redo branch
            $self->{_edit_depth} = undef;
        }
        else {
            $self->{_edit_depth}++;
        }
    }
    $self->_sync_dirty();
    return;
}

sub _sync_dirty {
    my ($self) = @_;
    $self->{dirty} = (defined $self->{_edit_depth} && $self->{_edit_depth} == 0) ? 0 : 1;
    return $self->{dirty};
}

sub delete_selection {
    my ($self) = @_;
    my $b = $self->selection_bounds() or return 0;
    my ($sl, $sc, $el, $ec) = @$b;
    my $pt   = $self->{pt};
    my $off0 = $pt->line_col_to_offset($sl, $sc);
    my $off1 = $pt->line_col_to_offset($el, $ec);
    $self->clear_selection();
    return 0 if $off1 <= $off0;

    my $old_lc = $pt->line_count();
    $pt->delete($off0, $off1 - $off0);
    my $delta = $pt->line_count() - $old_lc;
    $self->{syntax}->invalidate($sl, $delta);

    my ($nl, $nc) = $pt->offset_to_line_col($off0);
    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_record_edit($sl);
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub insert_at_cursor {
    my ($self, $text) = @_;
    return 0 unless defined $text && length $text;

    if ($self->has_selection()) {
        $self->delete_selection();
    }

    my $pt     = $self->{pt};
    my $line   = $self->{cursor_line};
    my $col    = $self->{cursor_col};
    my $offset = $pt->line_col_to_offset($line, $col);
    my $old_lc = $pt->line_count();

    my $ok = $pt->insert($offset, $text);
    return 0 unless $ok;

    my $blen  = _byte_len($text);
    my $delta = $pt->line_count() - $old_lc;
    $self->{syntax}->invalidate($line, $delta);

    my ($nl, $nc) = $pt->offset_to_line_col($offset + $blen);
    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_record_edit($line);
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub delete_backward {
    my ($self) = @_;
    return $self->delete_selection() if $self->has_selection();

    my $pt     = $self->{pt};
    my $offset = $pt->line_col_to_offset($self->{cursor_line}, $self->{cursor_col});
    return 0 if $offset == 0;

    my $del_len = 1;
    if ($self->{cursor_col} == 0 && $self->{cursor_line} > 0) {
        # Handle CRLF line endings cleanly
        my $prev_line = $self->get_line($self->{cursor_line} - 1) // '';
        my $prev_end  = $pt->line_col_to_offset($self->{cursor_line} - 1, _byte_len($prev_line));
        my $gap       = $offset - $prev_end;
        $del_len = $gap if $gap == 2;
    }

    my $new_off = $offset - $del_len;
    my $old_lc  = $pt->line_count();
    my $ok      = $pt->delete($new_off, $del_len);
    return 0 unless $ok;

    my ($nl, $nc) = $pt->offset_to_line_col($new_off);
    my $delta = $pt->line_count() - $old_lc;
    $self->{syntax}->invalidate($nl, $delta);

    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_record_edit($nl);
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub delete_forward {
    my ($self) = @_;
    return $self->delete_selection() if $self->has_selection();

    my $pt     = $self->{pt};
    my $offset = $pt->line_col_to_offset($self->{cursor_line}, $self->{cursor_col});
    my $total  = $pt->byte_length();
    return 0 if $offset >= $total;

    my $del_len = 1;
    my $cur_line = $self->get_line($self->{cursor_line}) // '';
    if ($self->{cursor_col} >= _byte_len($cur_line) && $self->{cursor_line} + 1 < $pt->line_count()) {
        my $next_off = $pt->line_col_to_offset($self->{cursor_line} + 1, 0);
        my $gap      = $next_off - $offset;
        $del_len = $gap if $gap == 2;
    }

    my $old_lc = $pt->line_count();
    my $ok     = $pt->delete($offset, $del_len);
    return 0 unless $ok;

    my $delta = $pt->line_count() - $old_lc;
    $self->{syntax}->invalidate($self->{cursor_line}, $delta);

    $self->_record_edit($self->{cursor_line});
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub replace_range {
    my ($self, $sl, $sc, $el, $ec, $replacement) = @_;
    $replacement = '' unless defined $replacement;
    my $pt   = $self->{pt};
    my $off0 = $pt->line_col_to_offset($sl, $sc);
    my $off1 = $pt->line_col_to_offset($el, $ec);
    my $old_lc = $pt->line_count();

    if ($off1 > $off0) {
        $pt->delete($off0, $off1 - $off0);
        $self->_record_edit($sl);
    }
    if (length $replacement) {
        $pt->insert($off0, $replacement);
        $self->_record_edit($sl);
    }

    my $delta = $pt->line_count() - $old_lc;
    $self->{syntax}->invalidate($sl, $delta);

    $self->clear_selection();
    my ($nl, $nc) = $pt->offset_to_line_col($off0 + _byte_len($replacement));
    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub undo {
    my ($self) = @_;
    my $ok = $self->{pt}->undo();
    return 0 unless $ok;

    my $edit_line = @{ $self->{_undo_lines} } ? pop(@{ $self->{_undo_lines} }) : 0;
    push @{ $self->{_redo_lines} }, $edit_line;
    $self->{_edit_depth}-- if defined $self->{_edit_depth};
    $self->{syntax}->invalidate($edit_line, 0);

    $self->clear_selection();
    my ($nl, $nc) = $self->_clamp_line_col($self->{cursor_line}, $self->{cursor_col});
    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_sync_dirty();
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub redo {
    my ($self) = @_;
    my $ok = $self->{pt}->redo();
    return 0 unless $ok;

    my $edit_line = @{ $self->{_redo_lines} } ? pop(@{ $self->{_redo_lines} }) : 0;
    push @{ $self->{_undo_lines} }, $edit_line;
    $self->{_edit_depth}++ if defined $self->{_edit_depth};
    $self->{syntax}->invalidate($edit_line, 0);

    $self->clear_selection();
    my ($nl, $nc) = $self->_clamp_line_col($self->{cursor_line}, $self->{cursor_col});
    $self->{cursor_line} = $nl;
    $self->{cursor_col}  = $nc;
    $self->_sync_dirty();
    $self->_fire_change();
    $self->_fire_cursor();
    return 1;
}

sub save {
    my ($self, $path) = @_;
    my $target = (defined $path && length $path) ? $path : $self->{path};
    die "Document::save requires a file path" unless defined $target && length $target;

    $self->{pt}->save_file($target);
    $self->{path}        = $target;
    $self->{title}       = basename($target);
    $self->{_edit_depth} = 0;
    $self->{dirty}       = 0;

    my $detected = App::Codit::MT::Core::detect_language($target);
    if ($detected ne $self->{language} && $self->{language} eq 'text') {
        $self->{language} = $detected;
        $self->{syntax}->set_language($detected);
    }

    $self->_fire_save();
    return 1;
}

# ---------------------------------------------------------------------------
# Bookmarks, Git Gutter, and Search
# ---------------------------------------------------------------------------

sub toggle_bookmark {
    my ($self, $line) = @_;
    $line = $self->{cursor_line} unless defined $line;
    $line = int($line);
    if ($self->{bookmarks}{$line}) {
        delete $self->{bookmarks}{$line};
        return 0;
    }
    $self->{bookmarks}{$line} = 1;
    return 1;
}

sub set_bookmark {
    my ($self, $line, $val) = @_;
    return unless defined $line;
    $line = int($line);
    if ($val) {
        $self->{bookmarks}{$line} = 1;
    }
    else {
        delete $self->{bookmarks}{$line};
    }
    return;
}

sub clear_bookmarks {
    my ($self) = @_;
    $self->{bookmarks} = {};
    return;
}

sub set_git_gutter {
    my ($self, $map) = @_;
    $self->{git_gutter} = (ref($map) eq 'HASH') ? { %$map } : {};
    return $self->{git_gutter};
}

sub set_search_matches {
    my ($self, $matches) = @_;
    $self->{search_matches} = (ref($matches) eq 'ARRAY') ? $matches : [];
    $self->{active_match_index} = undef;
    return $self->{search_matches};
}

sub clear_search_matches {
    my ($self) = @_;
    $self->{search_matches} = [];
    $self->{active_match_index} = undef;
    return;
}

sub search_buffer {
    my ($self, $query, $icase, $max_matches) = @_;
    if (!defined $query || !length $query) {
        $self->clear_search_matches();
        return [];
    }
    $icase       = $icase ? 1 : 0;
    $max_matches = 10000 unless defined $max_matches;
    my $matches  = $self->{pt}->search($query, $icase, $max_matches);
    $self->{search_matches} = $matches || [];
    $self->{active_match_index} = @{ $self->{search_matches} } ? 0 : undef;
    return $self->{search_matches};
}

1;

__END__

=head1 NAME

App::Codit::MT::Document - Piece-table document model with incremental syntax, cursor, gutter, and search state

=head1 SYNOPSIS

    use App::Codit::MT::Document;

    my $doc = App::Codit::MT::Document->open_file('script.pl');
    $doc->goto_line(10, 0);
    $doc->insert_at_cursor("# comment\n");
    $doc->undo();
    $doc->save();

=head1 DESCRIPTION

C<App::Codit::MT::Document> wraps L<App::Codit::MT::Core::PieceTable> and
L<App::Codit::MT::Core::Syntax> with editor state including file path, dirty
tracking, cursor and selection coordinates, bookmarks, Git diff gutter markers,
in-buffer search matches, and multi-listener event callbacks.

All line and column coordinates are 0-based.

=head1 METHODS

=over 4

=item C<open_file($path, %opts)> / C<new_empty($name, $lang, %opts)> / C<from_string($str, %opts)>

Construct a document from an existing file on disk, an empty buffer, or an
in-memory string.

=item C<save($path?)>

Atomically save the buffer to C<$path> (or the document's current path), reset
the dirty flag, and fire C<on_save> listeners.

=item C<insert_at_cursor($text)>, C<delete_backward()>, C<delete_forward()>, C<delete_selection()>, C<replace_range($sl, $sc, $el, $ec, $text)>

Mutate the buffer, incrementally invalidate syntax state, update cursor and
dirty status, and notify C<on_change> and C<on_cursor> listeners.

=item C<undo()>, C<redo()>, C<can_undo()>, C<can_redo()>

Step through the piece-table undo/redo stack.

=item C<goto_line($line, $col = 0)>, C<cursor()>, C<cursor_line()>, C<cursor_col()>

Query or move the cursor with clamping to valid line and column bounds.

=item C<get_line($line)>, C<get_lines($start, $count)>, C<line_count()>, C<byte_length()>, C<to_string()>, C<tokenize_range($first_line, $count)>

Read lines, buffer metrics, and syntax token spans.

=item C<search_buffer($query, $icase = 0, $max_matches = 10000)>

Search the buffer via C<PieceTable::search> and store the resulting spans in
C<search_matches()>.

=item C<bookmarks()>, C<toggle_bookmark($line)>, C<git_gutter()>, C<set_git_gutter(\%map)>

Manage per-line bookmark and Git diff gutter annotations.

=item C<on_change($cb)>, C<on_cursor($cb)>, C<on_save($cb)>

Register event callbacks (returning a listener ID that can be passed to
C<off_change>, C<off_cursor>, or C<off_save>).

=back

=cut
