package App::Codit::MT::CodeView::GPU;

use strict;
use warnings;

use Scalar::Util qw(weaken);
use Time::HiRes qw(time);
use Tcl::Tk::MT ();
use Tcl::Tk::MT::Canvas ();
use App::Codit::MT::Core qw(:tokens);

our $VERSION = '0.01';

# Tokyo-Night / One-Dark palette
my %COLORS = (
    bg             => '#0f111a',
    gutter_bg      => '#161926',
    gutter_sep     => '#2a2f45',
    active_line    => '#1e2233',
    line_num       => '#7a84b0',
    line_num_cur   => '#c0caf5',
    selection      => '#283457',
    search_match   => '#4a3b18',
    search_outline => '#d29922',
    cursor         => '#7aa2f7',
    bookmark       => '#58a6ff',
    git_add        => '#3fb950',
    git_mod        => '#d29922',
    git_del        => '#f85149',
);

# Indexed by App::Codit::MT::Core TOK_* constants (0..9)
my @TOK_COLORS = (
    '#d6deeb',    # 0 TOK_NORMAL
    '#bb9af7',    # 1 TOK_KEYWORD
    '#9ece6a',    # 2 TOK_STRING
    '#7a84b0',    # 3 TOK_COMMENT
    '#ff9e64',    # 4 TOK_NUMBER
    '#7dcfff',    # 5 TOK_VAR
    '#7aa2f7',    # 6 TOK_FUNC
    '#2ac3de',    # 7 TOK_TYPE
    '#89ddff',    # 8 TOK_OPERATOR
    '#f7768e',    # 9 TOK_PREPROC
);

my %GIT_COLORS = (
    add => $COLORS{git_add},
    mod => $COLORS{git_mod},
    del => $COLORS{git_del},
);

sub new {
    my ($class, %opts) = @_;

    my $doc      = $opts{doc} or die "CodeView::GPU->new requires 'doc'";
    my $parent   = $opts{parent};
    my $headless = $opts{headless} ? 1 : 0;
    my $backend  = $opts{backend};
    my $backend_arg = (defined $backend && length $backend && lc($backend) ne 'auto')
        ? lc($backend)
        : undef;

    my $w = int($opts{width}  || 900);
    my $h = int($opts{height} || 600);
    $w = 200 if $w < 200;
    $h = 100 if $h < 100;

    my $font_family = $opts{font_family}
        // ($^O eq 'darwin' ? 'Menlo' : ($^O eq 'MSWin32' ? 'Consolas' : 'DejaVu Sans Mono'));
    my $font_size   = int($opts{font_size} || 13);
    my $line_h      = int($opts{line_height} || ($font_size + 6));
    my $char_w      = $opts{char_width} || ($font_size * 0.60);

    my $self = bless {
        doc            => $doc,
        parent         => $parent,
        headless       => $headless,
        on_scroll      => $opts{on_scroll},
        width          => $w,
        height         => $h,
        font           => [ $font_family, $font_size ],
        font_size      => $font_size,
        line_h         => $line_h,
        char_w         => $char_w,
        pad_y          => 4,
        gutter_w       => 58,
        top_line       => 0,
        left_col       => 0,
        last_render_ms => 0.0,
        cursor_visible => 1,
        blink_id       => undef,
        drag_anchor    => undef,
        container      => undef,
        canvas         => undef,
        vsb            => undef,
        hsb            => undef,
        _destroyed     => 0,
        _cb_change_id  => undef,
        _cb_cursor_id  => undef,
    }, $class;

    if (!$headless && defined $parent) {
        $self->_build_widgets($parent, $w, $h, $backend_arg);
    }
    else {
        $self->{canvas} = Tcl::Tk::MT::Canvas->new(
            undef,
            '-width'    => $w,
            '-height'   => $h,
            '-bg'       => $COLORS{bg},
            '-backend'  => $backend_arg,
            '-headless' => 1,
        );
    }

    # Calibrate monospace cell advance against the actual atlas font metrics
    if (!$opts{char_width} && defined $self->{canvas}) {
        $self->_calibrate_font_metrics();
    }

    # Subscribe to document changes with weakened self to avoid cycles
    my $weak_self = $self;
    weaken($weak_self);

    $self->{_cb_change_id} = $doc->on_change(sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_clamp_scroll();
        $weak_self->render_frame();
    });

    $self->{_cb_cursor_id} = $doc->on_cursor(sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->{cursor_visible} = 1;
        $weak_self->_ensure_cursor_visible();
        $weak_self->render_frame();
    });

    if (!$headless && defined $self->{container}) {
        $self->_schedule_blink();
    }

    return $self;
}

sub _build_widgets {
    my ($self, $parent, $w, $h, $backend_arg) = @_;

    my $container = $parent->ttkFrame('-style' => 'Dark.TFrame');
    $container->pack('-fill' => 'both', '-expand' => 1);
    $container->gridRowconfigure(0, '-weight' => 1);
    $container->gridColumnconfigure(0, '-weight' => 1);

    my $canvas = Tcl::Tk::MT::Canvas->new(
        $container,
        '-width'    => $w,
        '-height'   => $h,
        '-bg'       => $COLORS{bg},
        '-backend'  => $backend_arg,
        '-headless' => 0,
    );
    $canvas->grid('-row' => 0, '-column' => 0, '-sticky' => 'nsew');

    my $weak_self = $self;
    weaken($weak_self);

    my $vsb = $container->ttkScrollbar(
        '-orient'  => 'vertical',
        '-style'   => 'Dark.Vertical.TScrollbar',
        '-command' => sub {
            $weak_self->_on_vscroll(@_) if $weak_self && !$weak_self->{_destroyed};
        },
    );
    $vsb->grid('-row' => 0, '-column' => 1, '-sticky' => 'ns');

    my $hsb = $container->ttkScrollbar(
        '-orient'  => 'horizontal',
        '-style'   => 'Dark.Horizontal.TScrollbar',
        '-command' => sub {
            $weak_self->_on_hscroll(@_) if $weak_self && !$weak_self->{_destroyed};
        },
    );
    $hsb->grid('-row' => 1, '-column' => 0, '-sticky' => 'ew');

    $self->{container} = $container;
    $self->{canvas}    = $canvas;
    $self->{vsb}       = $vsb;
    $self->{hsb}       = $hsb;

    $self->_bind_events($canvas);
    return;
}

sub _calibrate_font_metrics {
    my ($self) = @_;
    my $canvas = $self->{canvas} or return;
    my $probe  = '0123456789abcdef';
    my $id = eval {
        $canvas->createText(
            0, 0,
            '-text'   => $probe,
            '-font'   => $self->{font},
            '-anchor' => 'nw',
        );
    };
    return unless defined $id;
    my $bb = eval { $canvas->bbox($id) };
    eval { $canvas->delete($id) };
    if (ref($bb) eq 'ARRAY' && @$bb >= 4) {
        my $tw = $bb->[2] - $bb->[0];
        if ($tw > 0) {
            my $measured = $tw / length($probe);
            if ($measured >= 4.0 && $measured <= $self->{font_size} * 1.5) {
                $self->{char_w} = $measured;
            }
        }
    }
    return;
}

sub _bind_events {
    my ($self, $canvas) = @_;
    my $weak_self = $self;
    weaken($weak_self);

    $canvas->bind('<Configure>', [ sub {
        my ($w, $nw, $nh) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_on_resize($nw, $nh);
    }, Tcl::Tk::MT::Ev('w', 'h') ]);

    $canvas->bind('<Button-1>', [ sub {
        my ($w, $x, $y) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_on_button1($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $canvas->bind('<B1-Motion>', [ sub {
        my ($w, $x, $y) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_on_b1_motion($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $canvas->bind('<MouseWheel>', [ sub {
        my ($w, $delta) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_on_wheel($delta);
    }, Tcl::Tk::MT::Ev('D') ]);

    $canvas->bind('<Button-4>', sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->scroll_to_line($weak_self->{top_line} - 3);
        $weak_self->render_frame();
    });

    $canvas->bind('<Button-5>', sub {
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->scroll_to_line($weak_self->{top_line} + 3);
        $weak_self->render_frame();
    });

    $canvas->bind('<KeyPress>', [ sub {
        my ($w, $keysym, $unicode, $state) = @_;
        return unless $weak_self && !$weak_self->{_destroyed};
        $weak_self->_on_keypress($keysym, $unicode, $state);
    }, Tcl::Tk::MT::Ev('K', 'A', 's') ]);

    return;
}

# ---------------------------------------------------------------------------
# Public Accessors & Viewport API
# ---------------------------------------------------------------------------

sub doc            { $_[0]{doc} }
sub canvas         { $_[0]{canvas} }
sub widget         { $_[0]{container} // $_[0]{canvas} }
sub top_line       { $_[0]{top_line} }
sub left_col       { $_[0]{left_col} }
sub last_render_ms { $_[0]{last_render_ms} }
sub engine_name    { 'gpu' }

sub backend_name {
    my ($self) = @_;
    return defined($self->{canvas}) ? $self->{canvas}->backend_name() : 'software';
}

sub visible_lines {
    my ($self) = @_;
    my $usable = $self->{height} - $self->{pad_y};
    my $rows   = int($usable / $self->{line_h});
    return $rows > 0 ? $rows : 1;
}

sub visible_cols {
    my ($self) = @_;
    my $usable = $self->{width} - $self->{gutter_w} - 12;
    my $cols   = int($usable / $self->{char_w});
    return $cols > 0 ? $cols : 20;
}

sub _clamp_scroll {
    my ($self) = @_;
    my $total   = $self->{doc}->line_count() || 1;
    my $max_top = $total - 1;
    $max_top = 0 if $max_top < 0;
    $self->{top_line} = 0        if $self->{top_line} < 0;
    $self->{top_line} = $max_top if $self->{top_line} > $max_top;
    $self->{left_col} = 0        if $self->{left_col} < 0;
    return;
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
    $self->_update_scrollbars();

    if ($changed && ref($self->{on_scroll}) eq 'CODE') {
        $self->{on_scroll}->($self->{top_line}, $self->visible_lines());
    }
    return $self->{top_line};
}

sub _ensure_cursor_visible {
    my ($self) = @_;
    my $cl  = $self->{doc}->cursor_line();
    my $cc  = $self->{doc}->cursor_col();
    my $vis = $self->visible_lines();
    my $top = $self->{top_line};

    if ($cl < $top) {
        $self->scroll_to_line($cl);
    }
    elsif ($cl >= $top + $vis) {
        $self->scroll_to_line($cl - $vis + 1);
    }

    my $vcols = $self->visible_cols();
    if ($cc < $self->{left_col}) {
        $self->{left_col} = $cc;
    }
    elsif ($cc >= $self->{left_col} + $vcols - 2) {
        $self->{left_col} = $cc - $vcols + 4;
        $self->{left_col} = 0 if $self->{left_col} < 0;
    }
    return;
}

sub _update_scrollbars {
    my ($self) = @_;
    return if $self->{headless};
    my $total = $self->{doc}->line_count() || 1;
    my $vis   = $self->visible_lines();

    if ($self->{vsb}) {
        my $first = $self->{top_line} / $total;
        my $last  = ($self->{top_line} + $vis) / $total;
        $first = 0.0 if $first < 0.0;
        $last  = 1.0 if $last  > 1.0;
        $last  = $first + 0.01 if $last < $first;
        eval { $self->{vsb}->set($first, $last) };
    }
    if ($self->{hsb}) {
        my $max_cols = 240;
        my $vcols    = $self->visible_cols();
        my $hfirst   = $self->{left_col} / $max_cols;
        my $hlast    = ($self->{left_col} + $vcols) / $max_cols;
        $hfirst = 0.0 if $hfirst < 0.0;
        $hlast  = 1.0 if $hlast  > 1.0;
        eval { $self->{hsb}->set($hfirst, $hlast) };
    }
    return;
}

# ---------------------------------------------------------------------------
# Visible-Line Culled GPU Rendering
# ---------------------------------------------------------------------------

sub _visible_search_matches {
    my ($self, $first_line, $last_line) = @_;
    my $matches = $self->{doc}->search_matches();
    return {} unless $matches && @$matches;

    # Binary search for first match with line >= $first_line
    my ($lo, $hi) = (0, $#$matches);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($matches->[$mid]{line} // 0) < $first_line) {
            $lo = $mid + 1;
        }
        else {
            $hi = $mid;
        }
    }

    my %by_line;
    for (my $i = $lo; $i < @$matches; $i++) {
        my $m  = $matches->[$i];
        my $ml = $m->{line} // next;
        last if $ml > $last_line;
        next if $ml < $first_line;
        push @{ $by_line{$ml} }, $m;
    }
    return \%by_line;
}

sub render_frame {
    my ($self) = @_;
    return 0 if $self->{_destroyed} || !defined($self->{canvas});

    my $t0 = time();

    my $doc      = $self->{doc};
    my $canvas   = $self->{canvas};
    my $total    = $doc->line_count() || 1;
    my $top      = $self->{top_line};
    my $left_col = $self->{left_col};
    my $w        = $self->{width};
    my $h        = $self->{height};
    my $line_h   = $self->{line_h};
    my $char_w   = $self->{char_w};
    my $pad_y    = $self->{pad_y};
    my $font     = $self->{font};

    my $digits = length("$total");
    $digits = 4 if $digits < 4;
    my $gutter_w = int($digits * $char_w) + 28;
    $self->{gutter_w} = $gutter_w;
    my $text_x0 = $gutter_w + 8;

    my $vis_rows = $self->visible_lines() + 1;
    my $vis_cols = $self->visible_cols() + 2;
    my $lines    = $doc->get_lines($top, $vis_rows);
    my $tokens   = $doc->tokenize_range($top, scalar(@$lines));

    my $cur_line   = $doc->cursor_line();
    my $cur_col    = $doc->cursor_col();
    my $sel_bounds = $doc->selection_bounds();
    my $bookmarks  = $doc->bookmarks();
    my $git_gutter = $doc->git_gutter();
    my $last_line  = $top + (@$lines ? $#$lines : 0);
    my $vis_match  = $self->_visible_search_matches($top, $last_line);
    my $cur_vis    = $self->{cursor_visible};

    $canvas->batch(sub {
        $canvas->delete('all');

        # Gutter background and separator
        $canvas->createRectangle(
            0, 0, $gutter_w, $h,
            '-fill'    => $COLORS{gutter_bg},
            '-outline' => '',
        );
        $canvas->createLine(
            $gutter_w, 0, $gutter_w, $h,
            '-fill'  => $COLORS{gutter_sep},
            '-width' => 1,
        );

        for my $r (0 .. $#$lines) {
            my $line_no = $top + $r;
            my $y       = $pad_y + $r * $line_h;
            my $y2      = $y + $line_h;
            my $text    = $lines->[$r] // '';
            my $tlen    = length($text);

            # Active line highlight
            if ($line_no == $cur_line) {
                $canvas->createRectangle(
                    $gutter_w + 1, $y, $w, $y2,
                    '-fill'    => $COLORS{active_line},
                    '-outline' => '',
                );
            }

            # Bookmark indicator dot
            if ($bookmarks->{$line_no}) {
                my $cy = $y + int($line_h / 2);
                $canvas->createOval(
                    5, $cy - 4, 13, $cy + 4,
                    '-fill'    => $COLORS{bookmark},
                    '-outline' => '',
                );
            }

            # Git diff gutter bar
            if (my $gkind = $git_gutter->{$line_no}) {
                if (my $gcol = $GIT_COLORS{$gkind}) {
                    $canvas->createRectangle(
                        $gutter_w - 4, $y + 1, $gutter_w - 1, $y2 - 1,
                        '-fill'    => $gcol,
                        '-outline' => '',
                    );
                }
            }

            # Line number (1-based display)
            my $lnum = sprintf('%*d', $digits, $line_no + 1);
            $canvas->createText(
                16, $y + 2,
                '-text'   => $lnum,
                '-fill'   => ($line_no == $cur_line ? $COLORS{line_num_cur} : $COLORS{line_num}),
                '-font'   => $font,
                '-anchor' => 'nw',
            );

            # Selection highlight on this line
            if ($sel_bounds) {
                my ($sl, $sc, $el, $ec) = @$sel_bounds;
                if ($line_no >= $sl && $line_no <= $el) {
                    my $s0 = ($line_no == $sl) ? $sc : 0;
                    my $s1 = ($line_no == $el) ? $ec : ($tlen + 1);
                    my $vs0 = $s0 > $left_col ? $s0 : $left_col;
                    my $vs1 = $s1 < ($left_col + $vis_cols) ? $s1 : ($left_col + $vis_cols);
                    if ($vs1 > $vs0) {
                        $canvas->createRectangle(
                            $text_x0 + ($vs0 - $left_col) * $char_w, $y,
                            $text_x0 + ($vs1 - $left_col) * $char_w, $y2,
                            '-fill'    => $COLORS{selection},
                            '-outline' => '',
                        );
                    }
                }
            }

            # Search match highlights on this line
            if (my $mlist = $vis_match->{$line_no}) {
                for my $m (@$mlist) {
                    my $m0  = $m->{col} // 0;
                    my $m1  = $m0 + ($m->{len} || 1);
                    my $vm0 = $m0 > $left_col ? $m0 : $left_col;
                    my $vm1 = $m1 < ($left_col + $vis_cols) ? $m1 : ($left_col + $vis_cols);
                    next if $vm1 <= $vm0;
                    $canvas->createRectangle(
                        $text_x0 + ($vm0 - $left_col) * $char_w, $y + 1,
                        $text_x0 + ($vm1 - $left_col) * $char_w, $y2 - 1,
                        '-fill'    => $COLORS{search_match},
                        '-outline' => $COLORS{search_outline},
                    );
                }
            }

            # Syntax-colored text spans (clipped to visible columns)
            if ($tlen > $left_col) {
                my $row_toks = $tokens->[$r];
                my $max_col  = $left_col + $vis_cols;

                if ($row_toks && @$row_toks) {
                    my $nt = scalar @$row_toks;
                    for (my $ti = 0; $ti + 2 < $nt; $ti += 3) {
                        my $tc   = $row_toks->[$ti];
                        my $tl   = $row_toks->[$ti + 1];
                        my $type = $row_toks->[$ti + 2];
                        my $te   = $tc + $tl;
                        next if $te <= $left_col;
                        last if $tc >= $max_col;

                        my $vc0 = $tc > $left_col ? $tc : $left_col;
                        my $vc1 = $te < $max_col  ? $te : $max_col;
                        $vc1 = $tlen if $vc1 > $tlen;
                        next if $vc1 <= $vc0;

                        my $slice = substr($text, $vc0, $vc1 - $vc0);
                        $slice =~ tr/\t/ /;
                        next if $slice =~ /\A +\z/;

                        my $color = $TOK_COLORS[$type] // $TOK_COLORS[0];
                        $canvas->createText(
                            $text_x0 + ($vc0 - $left_col) * $char_w, $y + 2,
                            '-text'   => $slice,
                            '-fill'   => $color,
                            '-font'   => $font,
                            '-anchor' => 'nw',
                        );
                    }
                }
                else {
                    my $vc1   = $tlen < $max_col ? $tlen : $max_col;
                    my $slice = substr($text, $left_col, $vc1 - $left_col);
                    $slice =~ tr/\t/ /;
                    if ($slice !~ /\A *\z/) {
                        $canvas->createText(
                            $text_x0, $y + 2,
                            '-text'   => $slice,
                            '-fill'   => $TOK_COLORS[0],
                            '-font'   => $font,
                            '-anchor' => 'nw',
                        );
                    }
                }
            }

            # Blinking cursor bar
            if ($line_no == $cur_line && $cur_vis) {
                my $cx = $text_x0 + ($cur_col - $left_col) * $char_w;
                if ($cx >= $text_x0 - 2 && $cx <= $w) {
                    $canvas->createRectangle(
                        $cx, $y + 1, $cx + 2, $y2 - 1,
                        '-fill'    => $COLORS{cursor},
                        '-outline' => '',
                    );
                }
            }
        }
    });

    $canvas->render();
    $self->_update_scrollbars();

    $self->{last_render_ms} = (time() - $t0) * 1000.0;
    return $self->{last_render_ms};
}

# ---------------------------------------------------------------------------
# Input & Scroll Event Handlers
# ---------------------------------------------------------------------------

sub _xy_to_line_col {
    my ($self, $x, $y) = @_;
    my $row  = int(($y - $self->{pad_y}) / $self->{line_h});
    $row = 0 if $row < 0;
    my $line = $self->{top_line} + $row;

    my $text_x0 = $self->{gutter_w} + 8;
    my $col = $self->{left_col} + int(($x - $text_x0 + ($self->{char_w} * 0.5)) / $self->{char_w});
    $col = 0 if $col < 0;
    return ($line, $col);
}

sub _on_resize {
    my ($self, $nw, $nh) = @_;
    $nw = int($nw || 0);
    $nh = int($nh || 0);
    return if $nw < 20 || $nh < 20;
    return if $nw == $self->{width} && $nh == $self->{height};
    $self->{width}  = $nw;
    $self->{height} = $nh;
    $self->{canvas}->configure('-width' => $nw, '-height' => $nh);
    $self->render_frame();
    return;
}

sub _on_button1 {
    my ($self, $x, $y) = @_;
    eval { $self->{canvas}->focus() } if defined($self->{canvas}) && !$self->{headless};
    my ($line, $col) = $self->_xy_to_line_col($x, $y);
    ($line, $col) = $self->{doc}->goto_line($line, $col);
    $self->{drag_anchor}    = [ $line, $col ];
    $self->{cursor_visible} = 1;
    return;
}

sub _on_b1_motion {
    my ($self, $x, $y) = @_;
    my $anchor = $self->{drag_anchor} or return;
    my ($line, $col) = $self->_xy_to_line_col($x, $y);
    $self->{doc}->set_selection($anchor->[0], $anchor->[1], $line, $col);
    return;
}

sub _on_wheel {
    my ($self, $delta) = @_;
    $delta = int($delta || 0);
    return if $delta == 0;
    my $step = (abs($delta) >= 120) ? int(-$delta / 40) : int(-$delta * 3);
    $step = ($delta > 0 ? -3 : 3) if $step == 0;
    $self->scroll_to_line($self->{top_line} + $step);
    $self->render_frame();
    return;
}

sub _on_vscroll {
    my ($self, $cmd, @args) = @_;
    return unless defined $cmd;
    my $total = $self->{doc}->line_count() || 1;
    my $vis   = $self->visible_lines();
    if ($cmd eq 'moveto') {
        my $frac = ($args[0] // 0) + 0;
        my $target = int($frac * $total);
        $self->scroll_to_line($target);
    }
    elsif ($cmd eq 'scroll') {
        my ($n, $what) = @args;
        my $step = ($what && $what =~ /page/i) ? ($vis - 2) : 3;
        $step = 1 if $step < 1;
        $self->scroll_to_line($self->{top_line} + int($n || 0) * $step);
    }
    $self->render_frame();
    return;
}

sub _on_hscroll {
    my ($self, $cmd, @args) = @_;
    return unless defined $cmd;
    my $max_cols = 240;
    if ($cmd eq 'moveto') {
        my $frac = ($args[0] // 0) + 0;
        $self->{left_col} = int($frac * $max_cols);
        $self->{left_col} = 0 if $self->{left_col} < 0;
    }
    elsif ($cmd eq 'scroll') {
        my ($n, $what) = @args;
        my $step = ($what && $what =~ /page/i) ? 20 : 4;
        $self->{left_col} += int($n || 0) * $step;
        $self->{left_col} = 0 if $self->{left_col} < 0;
    }
    $self->render_frame();
    return;
}

sub _move_cursor {
    my ($self, $nl, $nc, $extend) = @_;
    my $doc = $self->{doc};
    if ($extend) {
        my $anchor = $doc->sel_start() || [ $doc->cursor_line(), $doc->cursor_col() ];
        $doc->set_selection($anchor->[0], $anchor->[1], $nl, $nc);
    }
    else {
        $doc->goto_line($nl, $nc);
    }
    return;
}

sub _on_keypress {
    my ($self, $keysym, $unicode, $state) = @_;
    $keysym  //= '';
    $unicode //= '';
    $state   = int($state || 0);

    my $doc   = $self->{doc};
    my $shift = ($state & 0x01) ? 1 : 0;
    # Control (0x04) or macOS Command / Mod1 / Meta (0x08 | 0x10)
    my $accel = ($state & (0x04 | 0x08 | 0x10)) ? 1 : 0;

    $self->{cursor_visible} = 1;

    if ($accel) {
        my $lk = lc($keysym);
        if ($lk eq 'z') {
            if ($shift) {
                $doc->redo();
            }
            else {
                $doc->undo();
            }
            return;
        }
        elsif ($lk eq 'y') {
            $doc->redo();
            return;
        }
        elsif ($lk eq 'a') {
            my $last_l = ($doc->line_count() || 1) - 1;
            my $last_c = length($doc->get_line($last_l) // '');
            $doc->set_selection(0, 0, $last_l, $last_c);
            return;
        }
        # Let application-level shortcuts (Cmd/Ctrl+N/O/S/W/Q/F/B) pass through
        return;
    }

    my ($cl, $cc) = ($doc->cursor_line(), $doc->cursor_col());

    if ($keysym eq 'Left') {
        if ($cc > 0) {
            $self->_move_cursor($cl, $cc - 1, $shift);
        }
        elsif ($cl > 0) {
            my $prev_len = length($doc->get_line($cl - 1) // '');
            $self->_move_cursor($cl - 1, $prev_len, $shift);
        }
    }
    elsif ($keysym eq 'Right') {
        my $cur_len = length($doc->get_line($cl) // '');
        if ($cc < $cur_len) {
            $self->_move_cursor($cl, $cc + 1, $shift);
        }
        elsif ($cl + 1 < $doc->line_count()) {
            $self->_move_cursor($cl + 1, 0, $shift);
        }
    }
    elsif ($keysym eq 'Up') {
        $self->_move_cursor($cl - 1, $cc, $shift) if $cl > 0;
    }
    elsif ($keysym eq 'Down') {
        $self->_move_cursor($cl + 1, $cc, $shift) if $cl + 1 < $doc->line_count();
    }
    elsif ($keysym eq 'Home') {
        $self->_move_cursor($cl, 0, $shift);
    }
    elsif ($keysym eq 'End') {
        my $cur_len = length($doc->get_line($cl) // '');
        $self->_move_cursor($cl, $cur_len, $shift);
    }
    elsif ($keysym eq 'Prior') {
        my $vis = $self->visible_lines();
        $self->scroll_to_line($self->{top_line} - $vis);
        $self->_move_cursor($cl - $vis, $cc, $shift);
    }
    elsif ($keysym eq 'Next') {
        my $vis = $self->visible_lines();
        $self->scroll_to_line($self->{top_line} + $vis);
        $self->_move_cursor($cl + $vis, $cc, $shift);
    }
    elsif ($keysym eq 'BackSpace') {
        $doc->delete_backward();
    }
    elsif ($keysym eq 'Delete') {
        $doc->delete_forward();
    }
    elsif ($keysym eq 'Return' || $keysym eq 'KP_Enter') {
        my $cur_text = $doc->get_line($cl) // '';
        my $prefix   = substr($cur_text, 0, $cc);
        my ($indent) = ($prefix =~ /\A([ \t]*)/);
        $indent //= '';
        $doc->insert_at_cursor("\n$indent");
    }
    elsif ($keysym eq 'Tab') {
        $doc->insert_at_cursor('    ');
    }
    elsif (length($unicode) && ord($unicode) >= 32 && ord($unicode) != 127) {
        $doc->insert_at_cursor($unicode);
    }

    return;
}

# ---------------------------------------------------------------------------
# Cursor Blink Timer & Cleanup
# ---------------------------------------------------------------------------

sub _schedule_blink {
    my ($self) = @_;
    return if $self->{_destroyed} || $self->{headless} || !$self->{container};
    my $weak_self = $self;
    weaken($weak_self);
    $self->{blink_id} = eval {
        $self->{container}->after(550, sub {
            return unless $weak_self && !$weak_self->{_destroyed};
            $weak_self->{cursor_visible} = $weak_self->{cursor_visible} ? 0 : 1;
            $weak_self->render_frame();
            $weak_self->_schedule_blink();
        });
    };
    return;
}

sub destroy {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;

    if (defined $self->{blink_id} && $self->{container}) {
        eval { $self->{container}->afterCancel($self->{blink_id}) };
        $self->{blink_id} = undef;
    }
    if ($self->{doc}) {
        $self->{doc}->off_change($self->{_cb_change_id}) if defined $self->{_cb_change_id};
        $self->{doc}->off_cursor($self->{_cb_cursor_id}) if defined $self->{_cb_cursor_id};
    }
    if (defined $self->{canvas}) {
        eval { $self->{canvas}->destroy() };
        $self->{canvas} = undef;
    }
    if ($self->{container}) {
        eval { $self->{container}->destroy() };
        $self->{container} = undef;
    }
    return 1;
}

1;

__END__

=head1 NAME

App::Codit::MT::CodeView::GPU - Visible-line culled GPU-accelerated code editor viewport

=head1 SYNOPSIS

    use App::Codit::MT::CodeView::GPU;

    my $view = App::Codit::MT::CodeView::GPU->new(
        parent   => $frame,
        doc      => $doc,
        backend  => 'auto',
        headless => 0,
    );
    $view->scroll_to_line(1000);
    $view->render_frame();

=head1 DESCRIPTION

Renders an L<App::Codit::MT::Document> onto a L<Tcl::Tk::MT::Canvas> with
synchronized C<ttk::scrollbar> widgets. Only the currently visible rows
C<[top_line .. top_line + visible_lines]> are queried and emitted inside a
single C<< $canvas->batch(...) >> call, so per-frame draw work scales with
viewport height rather than total file length.

=cut
