package App::Codit::MT::CodeView::TkText;

use strict;
use warnings;

use Scalar::Util qw(weaken);
use Time::HiRes qw(time);
use Tcl::Tk::MT ();

our $VERSION = '0.01';

my %COLORS = (
    bg             => '#0f111a',
    gutter_bg      => '#161926',
    active_line    => '#1e2233',
    line_num       => '#565f89',
    selection      => '#283457',
    search_match   => '#4a3b18',
    cursor         => '#7aa2f7',
);

my @TOK_COLORS = (
    '#d6deeb',    # 0 TOK_NORMAL
    '#bb9af7',    # 1 TOK_KEYWORD
    '#9ece6a',    # 2 TOK_STRING
    '#565f89',    # 3 TOK_COMMENT
    '#ff9e64',    # 4 TOK_NUMBER
    '#7dcfff',    # 5 TOK_VAR
    '#7aa2f7',    # 6 TOK_FUNC
    '#2ac3de',    # 7 TOK_TYPE
    '#89ddff',    # 8 TOK_OPERATOR
    '#f7768e',    # 9 TOK_PREPROC
);

sub new {
    my ($class, %opts) = @_;

    my $doc      = $opts{doc} or die "CodeView::TkText->new requires 'doc'";
    my $parent   = $opts{parent};
    my $headless = $opts{headless} ? 1 : 0;
    my $w        = int($opts{width}  || 900);
    my $h        = int($opts{height} || 600);
    my $line_h   = int($opts{line_height} || 18);

    my $self = bless {
        doc            => $doc,
        parent         => $parent,
        headless       => $headless,
        on_scroll      => $opts{on_scroll},
        width          => $w,
        height         => $h,
        line_h         => $line_h,
        top_line       => 0,
        last_render_ms => 0.0,
        container      => undef,
        gutter         => undef,
        text           => undef,
        vsb            => undef,
        hsb            => undef,
        _own_mw        => undef,
        _loaded_rev    => -1,
        _syncing       => 0,
        _destroyed     => 0,
        _cb_change_id  => undef,
        _cb_cursor_id  => undef,
    }, $class;

    if (defined $parent) {
        $self->_build_widgets($parent);
    }
    else {
        # In headless mode without an explicit parent, try a withdrawn MainWindow
        # so native Tk text benchmarks/tests exercise the real Tk text widget.
        my $mw = eval {
            my $m = Tcl::Tk::MT::MainWindow->new('-title' => 'CoditTkTextHeadless');
            $m->withdraw();
            $m->geometry("${w}x${h}");
            $m;
        };
        if ($mw) {
            $self->{_own_mw} = $mw;
            $self->_build_widgets($mw);
        }
    }

    my $weak_self = $self;
    weaken($weak_self);

    $self->{_cb_change_id} = $doc->on_change(sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        return if $weak_self->{_syncing};
        $weak_self->_reload_text_from_doc();
        $weak_self->render_frame();
    });

    $self->{_cb_cursor_id} = $doc->on_cursor(sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        return if $weak_self->{_syncing};
        $weak_self->_sync_cursor_to_tk();
    });

    $self->_reload_text_from_doc() if $self->{text};
    return $self;
}

sub _build_widgets {
    my ($self, $parent) = @_;

    my $container = $parent->ttkFrame('-style' => 'Dark.TFrame');
    $container->pack('-fill' => 'both', '-expand' => 1);
    $container->gridRowconfigure(0, '-weight' => 1);
    $container->gridColumnconfigure(1, '-weight' => 1);

    my $gutter = $container->Text(
        '-width'              => 7,
        '-bg'                 => $COLORS{gutter_bg},
        '-fg'                 => $COLORS{line_num},
        '-font'               => 'TkFixedFont',
        '-wrap'               => 'none',
        '-state'              => 'disabled',
        '-takefocus'          => 0,
        '-borderwidth'        => 0,
        '-highlightthickness' => 0,
        '-padx'               => 4,
    );
    $gutter->grid('-row' => 0, '-column' => 0, '-sticky' => 'ns');

    my $text = $container->Text(
        '-bg'                 => $COLORS{bg},
        '-fg'                 => $TOK_COLORS[0],
        '-insertbackground'   => $COLORS{cursor},
        '-selectbackground'   => $COLORS{selection},
        '-selectforeground'   => $TOK_COLORS[0],
        '-font'               => 'TkFixedFont',
        '-wrap'               => 'none',
        '-undo'               => 1,
        '-borderwidth'        => 0,
        '-highlightthickness' => 0,
        '-padx'               => 6,
    );
    $text->grid('-row' => 0, '-column' => 1, '-sticky' => 'nsew');

    my $weak_self = $self;
    weaken($weak_self);

    my $vsb = $container->ttkScrollbar(
        '-orient'  => 'vertical',
        '-style'   => 'Dark.Vertical.TScrollbar',
        '-command' => sub {
            return unless $weak_self && !$weak_self->{_destroyed} && $weak_self->{text};
            $weak_self->{text}->yview(@_);
            $weak_self->_sync_top_line_from_tk();
            $weak_self->render_frame();
        },
    );
    $vsb->grid('-row' => 0, '-column' => 2, '-sticky' => 'ns');

    my $hsb = $container->ttkScrollbar(
        '-orient'  => 'horizontal',
        '-style'   => 'Dark.Horizontal.TScrollbar',
        '-command' => sub {
            return unless $weak_self && !$weak_self->{_destroyed} && $weak_self->{text};
            $weak_self->{text}->xview(@_);
        },
    );
    $hsb->grid('-row' => 1, '-column' => 1, '-sticky' => 'ew');

    $text->configure(
        '-yscrollcommand' => sub {
            my ($first, $last) = @_;
            eval { $vsb->set($first, $last) };
            if ($weak_self && !$weak_self->{_destroyed}) {
                $weak_self->_sync_top_line_from_tk();
            }
        },
        '-xscrollcommand' => sub {
            my ($first, $last) = @_;
            eval { $hsb->set($first, $last) };
        },
    );

    # Configure syntax color tags
    for my $i (0 .. $#TOK_COLORS) {
        $text->tag('configure', "tok_$i", '-foreground' => $TOK_COLORS[$i]);
    }
    $text->tag('configure', 'active_line',  '-background' => $COLORS{active_line});
    $text->tag('configure', 'search_match', '-background' => $COLORS{search_match});
    $text->tag('lower', 'active_line');

    $text->bind('<KeyRelease>', sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_sync_cursor_from_tk();
        $weak_self->render_frame();
    });
    $text->bind('<ButtonRelease-1>', sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_sync_cursor_from_tk();
        $weak_self->render_frame();
    });
    $text->bind('<Configure>', [ sub {
        my ($w, $nw, $nh) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->{width}  = int($nw) if $nw && $nw > 20;
        $weak_self->{height} = int($nh) if $nh && $nh > 20;
        $weak_self->render_frame();
    }, Tcl::Tk::MT::Ev('w', 'h') ]);

    $self->{container} = $container;
    $self->{gutter}    = $gutter;
    $self->{text}      = $text;
    $self->{vsb}       = $vsb;
    $self->{hsb}       = $hsb;
    return;
}

# ---------------------------------------------------------------------------
# Public Viewport Interface (identical to CodeView::GPU)
# ---------------------------------------------------------------------------

sub doc            { $_[0]{doc} }
sub canvas         { undef }
sub widget         { $_[0]{container} }
sub text_widget    { $_[0]{text} }
sub top_line       { $_[0]{top_line} }
sub last_render_ms { $_[0]{last_render_ms} }
sub engine_name    { 'tktext' }
sub backend_name   { 'tktext' }

sub visible_lines {
    my ($self) = @_;
    my $rows = int($self->{height} / $self->{line_h});
    return $rows > 0 ? $rows : 1;
}

sub scroll_to_line {
    my ($self, $line) = @_;
    $line = int($line // 0);
    my $total   = $self->{doc}->line_count() || 1;
    my $max_top = $total - 1;
    $max_top = 0 if $max_top < 0;
    $line = 0        if $line < 0;
    $line = $max_top if $line > $max_top;

    my $changed = ($line != $self->{top_line});
    $self->{top_line} = $line;

    if ($self->{text}) {
        my $frac = $total > 0 ? ($line / $total) : 0.0;
        eval { $self->{text}->yview('moveto', $frac) };
    }

    if ($changed && ref($self->{on_scroll}) eq 'CODE') {
        $self->{on_scroll}->($self->{top_line}, $self->visible_lines());
    }
    return $self->{top_line};
}

sub _reload_text_from_doc {
    my ($self) = @_;
    my $text = $self->{text} or return;
    my $rev  = $self->{doc}->revision();
    return if $rev == $self->{_loaded_rev};

    $self->{_syncing} = 1;
    eval {
        $text->delete('1.0', 'end');
        my $content = $self->{doc}->to_string();
        $text->insert('1.0', $content) if defined $content && length $content;
    };
    $self->{_loaded_rev} = $rev;
    $self->{_syncing}    = 0;
    return;
}

sub _sync_top_line_from_tk {
    my ($self) = @_;
    my $text = $self->{text} or return;
    my $idx  = eval { $text->index('@0,0') };
    if (defined $idx && $idx =~ /\A(\d+)\./) {
        my $new_top = $1 - 1;
        $new_top = 0 if $new_top < 0;
        if ($new_top != $self->{top_line}) {
            $self->{top_line} = $new_top;
            if (ref($self->{on_scroll}) eq 'CODE') {
                $self->{on_scroll}->($self->{top_line}, $self->visible_lines());
            }
        }
    }
    return;
}

sub _sync_cursor_to_tk {
    my ($self) = @_;
    my $text = $self->{text} or return;
    my $l = $self->{doc}->cursor_line() + 1;
    my $c = $self->{doc}->cursor_col();
    eval {
        $text->mark('set', 'insert', "$l.$c");
        $text->see("$l.$c");
    };
    return;
}

sub _sync_cursor_from_tk {
    my ($self) = @_;
    my $text = $self->{text} or return;
    my $idx  = eval { $text->index('insert') };
    if (defined $idx && $idx =~ /\A(\d+)\.(\d+)\z/) {
        $self->{_syncing} = 1;
        $self->{doc}->goto_line($1 - 1, $2);
        $self->{_syncing} = 0;
    }
    return;
}

sub render_frame {
    my ($self) = @_;
    return 0 if $self->{_destroyed};

    my $t0 = time();

    my $doc   = $self->{doc};
    my $top   = $self->{top_line};
    my $vis   = $self->visible_lines() + 1;
    my $total = $doc->line_count() || 1;

    if ($self->{text}) {
        $self->_reload_text_from_doc() if $doc->revision() != $self->{_loaded_rev};

        my $text   = $self->{text};
        my $gutter = $self->{gutter};
        my $end_l  = $top + $vis;
        $end_l = $total if $end_l > $total;
        my $count  = $end_l - $top;
        $count = 0 if $count < 0;

        my $start_idx = ($top + 1) . '.0';
        my $end_idx   = ($end_l + 1) . '.0';

        # Update line-number gutter for visible lines
        if ($gutter) {
            my $digits = length("$total");
            $digits = 4 if $digits < 4;
            my $gstr = join("\n", map { sprintf('%*d', $digits, $_ + 1) } ($top .. $end_l - 1));
            eval {
                $gutter->configure('-state' => 'normal', '-width' => $digits + 2);
                $gutter->delete('1.0', 'end');
                $gutter->insert('1.0', $gstr);
                $gutter->configure('-state' => 'disabled');
            };
        }

        # Re-apply syntax tags for visible window
        for my $i (1 .. $#TOK_COLORS) {
            eval { $text->tag('remove', "tok_$i", $start_idx, $end_idx) };
        }
        eval { $text->tag('remove', 'active_line',  '1.0', 'end') };
        eval { $text->tag('remove', 'search_match', $start_idx, $end_idx) };

        my $tokens = $doc->tokenize_range($top, $count);
        for my $r (0 .. $#$tokens) {
            my $tk_line  = $top + $r + 1;
            my $row_toks = $tokens->[$r] or next;
            my $nt       = scalar @$row_toks;
            for (my $ti = 0; $ti + 2 < $nt; $ti += 3) {
                my $tc   = $row_toks->[$ti];
                my $tl   = $row_toks->[$ti + 1];
                my $type = $row_toks->[$ti + 2];
                next if $type == 0 || $tl <= 0;
                my $te = $tc + $tl;
                $text->tag('add', "tok_$type", "$tk_line.$tc", "$tk_line.$te");
            }
        }

        # Active line highlight
        my $cl = $doc->cursor_line() + 1;
        eval { $text->tag('add', 'active_line', "$cl.0", "$cl.0 lineend + 1c") };

        # Visible search match highlights
        my $matches = $doc->search_matches();
        if ($matches && @$matches) {
            for my $m (@$matches) {
                my $ml = $m->{line} // next;
                next if $ml < $top;
                last if $ml >= $end_l;
                my $tk_l = $ml + 1;
                my $c0   = $m->{col} // 0;
                my $c1   = $c0 + ($m->{len} || 1);
                $text->tag('add', 'search_match', "$tk_l.$c0", "$tk_l.$c1");
            }
        }

        eval { $text->interp->icall('update', 'idletasks') };
    }
    else {
        # Pure-headless fallback when no Tk display is available
        my $lines  = $doc->get_lines($top, $vis);
        my $tokens = $doc->tokenize_range($top, scalar(@$lines));
    }

    $self->{last_render_ms} = (time() - $t0) * 1000.0;
    return $self->{last_render_ms};
}

sub destroy {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;

    if ($self->{doc}) {
        $self->{doc}->off_change($self->{_cb_change_id}) if defined $self->{_cb_change_id};
        $self->{doc}->off_cursor($self->{_cb_cursor_id}) if defined $self->{_cb_cursor_id};
    }
    if ($self->{container}) {
        eval { $self->{container}->destroy() };
        $self->{container} = undef;
    }
    if ($self->{_own_mw}) {
        eval { $self->{_own_mw}->destroy() };
        $self->{_own_mw} = undef;
    }
    $self->{text}   = undef;
    $self->{gutter} = undef;
    return 1;
}

1;

__END__

=head1 NAME

App::Codit::MT::CodeView::TkText - Native Tk Text viewport implementing the CodeView interface

=head1 SYNOPSIS

    use App::Codit::MT::CodeView::TkText;

    my $view = App::Codit::MT::CodeView::TkText->new(
        parent => $frame,
        doc    => $doc,
    );

=head1 DESCRIPTION

Wraps a standard Tk C<text> widget with a synchronized line-number gutter,
dark theme, and visible-window syntax tagging while exposing the exact same
API as L<App::Codit::MT::CodeView::GPU>.

=cut
