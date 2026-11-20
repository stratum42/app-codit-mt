package App::Codit::MT::Core;

use strict;
use warnings;
use XSLoader;

our $VERSION = '0.01';

use Exporter 'import';

use constant {
    TOK_NORMAL   => 0,
    TOK_KEYWORD  => 1,
    TOK_STRING   => 2,
    TOK_COMMENT  => 3,
    TOK_NUMBER   => 4,
    TOK_VAR      => 5,
    TOK_FUNC     => 6,
    TOK_TYPE     => 7,
    TOK_OPERATOR => 8,
    TOK_PREPROC  => 9,
};

our @EXPORT_OK = qw(
    TOK_NORMAL TOK_KEYWORD TOK_STRING TOK_COMMENT TOK_NUMBER
    TOK_VAR TOK_FUNC TOK_TYPE TOK_OPERATOR TOK_PREPROC
    detect_language tokenize_range search_dir minimap_render_rgba8
    is_perl5_mt have_packed_av force_scalar
);

our %EXPORT_TAGS = (
    tokens => [qw(
        TOK_NORMAL TOK_KEYWORD TOK_STRING TOK_COMMENT TOK_NUMBER
        TOK_VAR TOK_FUNC TOK_TYPE TOK_OPERATOR TOK_PREPROC
    )],
    all => \@EXPORT_OK,
);

XSLoader::load('App::Codit::MT::Core', $VERSION);

1;

__END__

=head1 NAME

App::Codit::MT::Core - Pure-C11 Tier-1 XS core engine for App::Codit::MT

=head1 SYNOPSIS

    use App::Codit::MT::Core qw(:tokens detect_language search_dir minimap_render_rgba8);

    my $pt  = App::Codit::MT::Core::PieceTable->open_file('script.pl');
    my $syn = App::Codit::MT::Core::Syntax->new(detect_language('script.pl'));

    my $lines  = $pt->get_lines(0, 40);
    my $tokens = $syn->tokenize_range($pt, 0, 40);
    my $rgba   = minimap_render_rgba8($pt, $syn, 120, 400, 0, 40);
    my $hits   = search_dir('.', 'sub ', 0, 1000);

=head1 DESCRIPTION

C<App::Codit::MT::Core> provides the native C11 engine behind L<App::Codit::MT>:

=over 4

=item * B<App::Codit::MT::Core::PieceTable>: zero-copy C<mmap>-backed document
buffer with append-only add buffer, contiguous line-start offset index, and
full undo/redo history.

=item * B<App::Codit::MT::Core::Syntax>: incremental per-line lexer supporting
C<perl>, C<c>, C<tcl>, C<python>, C<json>, C<shell>, C<markdown>, and C<text>.

=item * B<search_dir>: multi-threaded directory search honoring
C<PERL_FORCE_SCALAR=1> for deterministic bit-identical results.

=item * B<minimap_render_rgba8>: syntax-colored pixel-density minimap renderer
writing directly into a zero-copy packed C<MT::Array> C<U8> RGBA8888 buffer on
C<perl5-mt> (with automatic standard-AV fallback on stock Perl 5).

=back

=head1 SEE ALSO

L<App::Codit::MT>, L<App::Codit::MT::Document>

=head1 LICENSE

Same as Perl itself (dual Artistic License / GNU GPL).

=cut
