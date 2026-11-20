package App::Codit::MT::CodeView;

use strict;
use warnings;

our $VERSION = '0.01';

sub new {
    my ($class, %opts) = @_;

    my $engine  = lc($opts{engine}  // 'gpu');
    my $backend = lc($opts{backend} // 'auto');
    my $env_acc = defined($ENV{TCL_TK_MT_ACCEL}) ? lc($ENV{TCL_TK_MT_ACCEL}) : '';

    my $use_tktext = 0;
    if ($engine eq 'tktext' || $env_acc eq 'off' || $backend eq 'off') {
        $use_tktext = 1;
    }

    if ($use_tktext) {
        require App::Codit::MT::CodeView::TkText;
        return App::Codit::MT::CodeView::TkText->new(%opts);
    }

    require App::Codit::MT::CodeView::GPU;
    return App::Codit::MT::CodeView::GPU->new(%opts);
}

1;

__END__

=head1 NAME

App::Codit::MT::CodeView - Factory for GPU-accelerated and native Tk Text editor viewports

=head1 SYNOPSIS

    use App::Codit::MT::CodeView;

    my $view = App::Codit::MT::CodeView->new(
        parent   => $frame,
        doc      => $doc,
        engine   => 'gpu',
        backend  => 'auto',
        headless => 0,
    );

=head1 DESCRIPTION

Selects and constructs either L<App::Codit::MT::CodeView::GPU> (default) or
L<App::Codit::MT::CodeView::TkText> (when C<< engine => 'tktext' >>,
C<< backend => 'off' >>, or C<TCL_TK_MT_ACCEL=off>). Both implementations expose
an identical viewport interface so the IDE can toggle engines live or benchmark
them side-by-side.

=cut
