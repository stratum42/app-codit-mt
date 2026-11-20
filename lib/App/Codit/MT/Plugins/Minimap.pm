package App::Codit::MT::Plugins::Minimap;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

use App::Codit::MT::Core ();

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugins::Minimap - GPU-accelerated syntax-colored code minimap plugin

=head1 SYNOPSIS

    my $mm = App::Codit::MT::Plugins::Minimap->new();
    $mm->init($app);

=head1 DESCRIPTION

Adds a right-panel GPU minimap to L<App::Codit::MT> backed by
L<Tcl::Tk::MT::Canvas> and L<Tcl::Tk::MT::Photo> zero-copy C<put_rgba_packed>
uploads from C<App::Codit::MT::Core::minimap_render_rgba8>. Supports click and
drag viewport scrubbing synchronized with the active L<App::Codit::MT::CodeView>.

=cut

sub name { 'Minimap' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{width}      = $self->{width}  || 110;
    $self->{height}     = $self->{height} || 480;
    $self->{top_line}   = 0;
    $self->{vis_lines}  = 40;
    $self->{rgba_buf}   = undef;
    $self->{photo}      = undef;
    $self->{canvas}     = undef;
    $self->{img_id}     = undef;
    $self->{pending}    = undef;

    return if $app->headless || !$app->right_dock;

    require Tcl::Tk::MT;
    require Tcl::Tk::MT::Canvas;
    require Tcl::Tk::MT::Photo;

    my $dock    = $app->right_dock;
    my $theme   = $app->theme || {};
    my $bg      = $theme->{bg} || '#0f111a';
    my $backend = $app->backend;
    $backend    = 'software' if defined $backend && $backend eq 'off';
    $backend    = undef      if defined $backend && ($backend eq 'auto' || !length($backend));

    my $canvas = Tcl::Tk::MT::Canvas->new(
        $dock,
        -width      => $self->{width},
        -height     => $self->{height},
        -background => $bg,
        (defined $backend ? (-backend => $backend) : ()),
    );
    $self->{canvas} = $canvas;

    my $photo = Tcl::Tk::MT::Photo->new(
        $app->interp,
        -width   => $self->{width},
        -height  => $self->{height},
        -surface => $canvas->surface,
    );
    $self->{photo} = $photo;

    $canvas->bind('<Button-1>', [ sub {
        my ($w, $y) = @_;
        $self->_scrub_to_y($y);
    }, Tcl::Tk::MT::Ev('y') ]);

    $canvas->bind('<B1-Motion>', [ sub {
        my ($w, $y) = @_;
        $self->_scrub_to_y($y);
    }, Tcl::Tk::MT::Ev('y') ]);

    $canvas->bind('<Configure>', [ sub {
        my ($w, $nw, $nh) = @_;
        $self->_on_configure($nw, $nh);
    }, Tcl::Tk::MT::Ev('w', 'h') ]);

    $app->set_right_panel($canvas);
    return $self;
}

sub canvas { $_[0]{canvas} }
sub photo  { $_[0]{photo} }
sub width  { $_[0]{width} }
sub height { $_[0]{height} }

sub _on_configure {
    my ($self, $nw, $nh) = @_;
    return unless defined $nh && $nh >= 64;
    my $h = int($nh);
    $h = 1200 if $h > 1200;
    return if $h == $self->{height};

    $self->{height}   = $h;
    $self->{rgba_buf} = undef;
    $self->_schedule_render();
}

sub _scrub_to_y {
    my ($self, $y) = @_;
    my $app  = $self->app or return;
    my $doc  = $app->active_doc  or return;
    my $view = $app->active_view or return;

    my $total = $doc->line_count();
    return unless $total > 0;

    my $h = $self->{height} || 480;
    $y = 0  if !defined($y) || $y < 0;
    $y = $h if $y > $h;

    my $lines_per_row = ($total > $h) ? ($total / $h) : 1.0;
    my $vis           = ($view->can('visible_lines') ? $view->visible_lines : $self->{vis_lines}) || 40;
    my $center_line   = int($y * $lines_per_row);
    my $target_top    = $center_line - int($vis / 2);
    my $max_top       = $total - 1;
    $target_top = 0        if $target_top < 0;
    $target_top = $max_top if $target_top > $max_top;

    $self->{top_line}  = $target_top;
    $self->{vis_lines} = $vis;

    if ($view->can('scroll_to_line')) {
        $view->scroll_to_line($target_top);
    }
    $app->redraw_active();
    $self->render_minimap($doc, $target_top, $vis);
}

sub render_minimap {
    my ($self, $doc, $top_line, $vis_lines) = @_;
    my $app = $self->app;
    $doc ||= ($app ? $app->active_doc : undef);
    return undef unless $doc;

    my $pt  = $doc->can('piece_table') ? $doc->piece_table : undef;
    my $syn = $doc->can('syntax')      ? $doc->syntax      : undef;
    return undef unless $pt;

    my $view = $app ? $app->active_view : undef;
    if (!defined $top_line) {
        $top_line = ($view && $view->can('top_line')) ? ($view->top_line // 0) : $self->{top_line};
    }
    if (!defined $vis_lines) {
        $vis_lines = ($view && $view->can('visible_lines')) ? ($view->visible_lines || 40) : $self->{vis_lines};
    }

    $self->{top_line}  = $top_line;
    $self->{vis_lines} = $vis_lines;

    my $w = $self->{width}  || 110;
    my $h = $self->{height} || 480;

    my $buf = App::Codit::MT::Core::minimap_render_rgba8(
        $pt, $syn, $w, $h, $top_line, $vis_lines, $self->{rgba_buf},
    );
    $self->{rgba_buf} = $buf;

    my $canvas = $self->{canvas};
    my $photo  = $self->{photo};
    if ($canvas && $photo && defined $buf) {
        $photo->put_rgba_packed($buf, $w, $h);
        if (!defined $self->{img_id}) {
            $self->{img_id} = $canvas->createImage(0, 0, -anchor => 'nw', -image => $photo);
        }
        else {
            $canvas->itemconfigure($self->{img_id}, -image => $photo);
        }
        $canvas->render();
    }

    return $buf;
}

sub _schedule_render {
    my ($self) = @_;
    my $app = $self->app or return;
    if ($app->headless) {
        $self->render_minimap();
        return;
    }
    return if defined $self->{pending};
    $self->{pending} = $app->after(16, sub {
        $self->{pending} = undef;
        $self->render_minimap();
    });
}

sub on_doc_open {
    my ($self, $doc) = @_;
    $self->render_minimap($doc, 0, $self->{vis_lines});
}

sub on_doc_switch {
    my ($self, $doc) = @_;
    $self->render_minimap($doc);
}

sub on_doc_change {
    my ($self, $doc) = @_;
    $self->_schedule_render();
}

sub on_doc_save {
    my ($self, $doc) = @_;
    $self->_schedule_render();
}

sub on_scroll {
    my ($self, $doc, $top_line, $vis_lines) = @_;
    $self->{top_line}  = $top_line  if defined $top_line;
    $self->{vis_lines} = $vis_lines if defined $vis_lines;
    $self->_schedule_render();
}

sub shutdown {
    my ($self) = @_;
    my $app = $self->app;
    if ($app && defined $self->{pending}) {
        $app->after_cancel($self->{pending});
        $self->{pending} = undef;
    }
    $self->{rgba_buf} = undef;
}

1;
