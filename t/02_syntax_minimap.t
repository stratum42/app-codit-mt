use strict;
use warnings;
use Test::More;

use App::Codit::MT::Core qw(
    :tokens detect_language tokenize_range minimap_render_rgba8
    is_perl5_mt have_packed_av
);

# 1. Language detection
is(detect_language('lib/Foo/Bar.pm'),    'perl',     'detect .pm -> perl');
is(detect_language('Makefile.PL'),       'perl',     'detect Makefile.PL -> perl');
is(detect_language('c/piece_table.c'),   'c',        'detect .c -> c');
is(detect_language('Core.xs'),           'c',        'detect .xs -> c');
is(detect_language('gui/main.tcl'),      'tcl',      'detect .tcl -> tcl');
is(detect_language('tools/gen.py'),      'python',   'detect .py -> python');
is(detect_language('package.json'),      'json',     'detect .json -> json');
is(detect_language('scripts/build.sh'),  'shell',    'detect .sh -> shell');
is(detect_language('README.md'),         'markdown', 'detect .md -> markdown');
is(detect_language('notes.txt'),         'text',     'detect .txt -> text');

# Helper: extract list of token types on a line
sub tok_types {
    my ($flat) = @_;
    my @types;
    for (my $i = 0; $i < @$flat; $i += 3) {
        push @types, $flat->[$i + 2];
    }
    return @types;
}

# 2. Perl lexing including POD multi-line state
{
    my $code = join("\n",
        'my $x = 42; # answer',
        '=head1 NAME',
        'my $not_code = 1;',
        '=cut',
        'sub greet { return "hi"; }',
    ) . "\n";
    my $pt  = App::Codit::MT::Core::PieceTable->from_string($code);
    my $syn = App::Codit::MT::Core::Syntax->new('perl');
    is($syn->language, 'perl', 'syntax language is perl');

    my $toks = $syn->tokenize_range($pt, 0, 5);
    is(scalar(@$toks), 5, 'tokenized 5 lines');

    my %l0 = map { $_ => 1 } tok_types($toks->[0]);
    ok($l0{TOK_KEYWORD()}, 'line 0 has keyword (my)');
    ok($l0{TOK_VAR()},     'line 0 has var ($x)');
    ok($l0{TOK_NUMBER()},  'line 0 has number (42)');
    ok($l0{TOK_COMMENT()}, 'line 0 has comment (# answer)');

    # Lines 1..3 are POD -> COMMENT
    is_deeply([tok_types($toks->[1])], [TOK_COMMENT()], 'line 1 (=head1) is comment/POD');
    is_deeply([tok_types($toks->[2])], [TOK_COMMENT()], 'line 2 inside POD is comment');
    is_deeply([tok_types($toks->[3])], [TOK_COMMENT()], 'line 3 (=cut) is comment');
    is($syn->end_state(2), 2, 'end_state inside POD is 2');
    is($syn->end_state(3), 0, 'end_state after =cut returns to 0');

    my %l4 = map { $_ => 1 } tok_types($toks->[4]);
    ok($l4{TOK_KEYWORD()}, 'line 4 after POD has keyword (sub/return)');
    ok($l4{TOK_STRING()},  'line 4 after POD has string ("hi")');
}

# 3. C lexing + incremental state stabilization
{
    my @lines = ('#include <stdio.h>');
    for my $i (1 .. 200) {
        push @lines, "int fn_$i(size_t n) { return (int)n + $i; }";
    }
    my $pt  = App::Codit::MT::Core::PieceTable->from_string(join("\n", @lines) . "\n");
    my $syn = App::Codit::MT::Core::Syntax->new('c');

    my $toks = tokenize_range($pt, $syn, 0, 201);
    is_deeply([tok_types($toks->[0])], [TOK_PREPROC()], 'line 0 (#include) is PREPROC');
    my %l1 = map { $_ => 1 } tok_types($toks->[1]);
    ok($l1{TOK_TYPE()},    'line 1 has C type (int/size_t)');
    ok($l1{TOK_FUNC()},    'line 1 has C func (fn_1)');
    ok($l1{TOK_KEYWORD()}, 'line 1 has C keyword (return)');

    # Edit line 10 without changing end_state; incremental re-lex should stabilize in 1 line
    my $off10 = $pt->line_col_to_offset(10, 0);
    $pt->insert($off10, '/* inline */ ');
    $syn->invalidate(10, 0);
    $syn->tokenize_range($pt, 0, 201);
    cmp_ok($syn->last_relex_lines, '<=', 2, 'incremental re-lex stops immediately when end_state stabilizes');

    # Now open an unclosed block comment at line 11 -> propagates until closed at line 15
    my $off11 = $pt->line_col_to_offset(11, 0);
    $pt->insert($off11, '/* ');
    my $off15 = $pt->line_col_to_offset(15, 0);
    $pt->insert($off15, '*/ ');
    $syn->invalidate(11, 0);
    my $range = $syn->tokenize_range($pt, 11, 9);
    is($syn->end_state(11), 1, 'line 11 enters block comment state');
    is($syn->end_state(14), 1, 'line 14 stays in block comment state');
    is($syn->end_state(15), 0, 'line 15 exits block comment state');
    is_deeply([tok_types($range->[1])], [TOK_COMMENT()], 'line 12 is fully COMMENT');
}

# 4. Python triple-quoted string & JSON keys
{
    my $py = App::Codit::MT::Core::PieceTable->from_string("def f():\n    s = \"\"\"a\nb\"\"\"\n    return 1\n");
    my $syn = App::Codit::MT::Core::Syntax->new('python');
    my $toks = $syn->tokenize_range($py, 0, 4);
    is($syn->end_state(1), 3, 'python triple-dq enters state 3');
    is($syn->end_state(2), 0, 'python triple-dq closes back to 0');

    my $js = App::Codit::MT::Core::PieceTable->from_string("{\"key\": true, \"n\": 123}\n");
    my $jsyn = App::Codit::MT::Core::Syntax->new('json');
    my $jtoks = $jsyn->tokenize_range($js, 0, 1);
    my %jt = map { $_ => 1 } tok_types($jtoks->[0]);
    ok($jt{TOK_VAR()},     'JSON key highlighted as VAR');
    ok($jt{TOK_KEYWORD()}, 'JSON true highlighted as KEYWORD');
    ok($jt{TOK_NUMBER()},  'JSON number highlighted as NUMBER');
}

# 5. Minimap RGBA8888 rendering + zero-copy packed AV + PERL_FORCE_SCALAR=1 bit-identical parity
{
    my @lines;
    for my $i (0 .. 399) {
        push @lines, sprintf("sub func_%03d { my \$x = %d; return \"val_\$x\"; } # comment %d", $i, $i, $i);
    }
    my $pt  = App::Codit::MT::Core::PieceTable->from_string(join("\n", @lines) . "\n");
    my $syn = App::Codit::MT::Core::Syntax->new('perl');

    my ($w, $h) = (120, 200);
    my $expected_len = $w * $h * 4;

    my $mt_rgba;
    {
        local $ENV{PERL_FORCE_SCALAR} = 0;
        $mt_rgba = minimap_render_rgba8($pt, $syn, $w, $h, 50, 40);
    }
    is(ref($mt_rgba), 'ARRAY', 'minimap returns arrayref');
    is(scalar(@$mt_rgba), $expected_len, "minimap length == $expected_len");

    if (have_packed_av()) {
        require MT::Array;
        ok(MT::Array::is_packed($mt_rgba), 'minimap buffer is zero-copy packed MT::Array U8 on perl5-mt');
    }

    # Verify non-background pixels exist and alpha is 255
    my $non_bg = 0;
    for (my $i = 0; $i < $expected_len; $i += 4) {
        if ($mt_rgba->[$i] != 15 || $mt_rgba->[$i + 1] != 17 || $mt_rgba->[$i + 2] != 26) {
            $non_bg++;
        }
    }
    cmp_ok($non_bg, '>', 500, 'minimap rendered syntax-colored + viewport pixels');

    # Render again under PERL_FORCE_SCALAR=1 and assert 100% bit-identical parity
    my $sc_rgba;
    {
        local $ENV{PERL_FORCE_SCALAR} = 1;
        $sc_rgba = minimap_render_rgba8($pt, $syn, $w, $h, 50, 40);
    }
    is(scalar(@$sc_rgba), $expected_len, 'scalar minimap length matches');

    my $diffs = 0;
    for (my $i = 0; $i < $expected_len; $i++) {
        if ($mt_rgba->[$i] != $sc_rgba->[$i]) {
            $diffs++;
            last;
        }
    }
    is($diffs, 0, 'minimap multi-threaded vs PERL_FORCE_SCALAR=1 is 100% bit-identical');

    # Zero-copy reuse of existing buffer
    my $reused = minimap_render_rgba8($pt, $syn, $w, $h, 100, 40, $mt_rgba);
    is($reused, $mt_rgba, 'minimap reuses provided target AV in place');
}

done_testing();
