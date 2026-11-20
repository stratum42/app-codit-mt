use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(time);

use App::Codit::MT::Core;

# 1. Empty PieceTable
{
    my $pt = App::Codit::MT::Core::PieceTable->new();
    isa_ok($pt, 'App::Codit::MT::Core::PieceTable');
    is($pt->byte_length, 0, 'empty byte_length == 0');
    is($pt->line_count,  1, 'empty line_count == 1');
    is($pt->get_line(0), '', 'empty line 0 is ""');
    is($pt->to_string,   '', 'empty to_string is ""');
    is($pt->can_undo,    0, 'cannot undo initially');
    is($pt->can_redo,    0, 'cannot redo initially');
    is($pt->undo,        0, 'undo on empty returns 0');
    is($pt->redo,        0, 'redo on empty returns 0');

    ok($pt->insert(0, "hello world\nsecond line\n"), 'insert into empty');
    is($pt->line_count, 3, 'line_count after 2 newlines is 3');
    is($pt->get_line(0), 'hello world', 'line 0');
    is($pt->get_line(1), 'second line', 'line 1');
    is($pt->get_line(2), '', 'line 2');
    is($pt->can_undo, 1, 'can_undo after insert');

    # Insert in the middle (splits piece)
    ok($pt->insert(5, " MT"), 'insert in middle');
    is($pt->get_line(0), 'hello MT world', 'line 0 after middle insert');

    # Sequential typing coalescing
    ok($pt->insert(8, "!"), 'sequential append into add piece');
    is($pt->get_line(0), 'hello MT! world', 'line 0 after sequential insert');

    # Delete across newline boundary
    my $off = $pt->line_col_to_offset(0, 9);
    is($off, 9, 'line_col_to_offset(0, 9)');
    my ($l, $c) = $pt->offset_to_line_col($off);
    is_deeply([$l, $c], [0, 9], 'offset_to_line_col list context');
    my $pair = $pt->offset_to_line_col($pt->line_col_to_offset(1, 3));
    is_deeply($pair, [1, 3], 'offset_to_line_col scalar context');

    my $before_del = $pt->to_string;
    ok($pt->delete(9, 10), 'delete spanning newline');
    isnt($pt->to_string, $before_del, 'content changed after delete');

    # Undo / Redo round-trip
    is($pt->undo, 1, 'undo delete');
    is($pt->to_string, $before_del, 'content restored after undo');
    is($pt->can_redo, 1, 'can_redo after undo');
    is($pt->redo, 1, 'redo delete');
    isnt($pt->to_string, $before_del, 'redo re-applied delete');

    # Undo everything back to empty
    while ($pt->can_undo) {
        $pt->undo;
    }
    is($pt->to_string, '', 'undid all the way to empty');
    is($pt->byte_length, 0, 'byte_length == 0 after full undo');
    is($pt->line_count, 1, 'line_count == 1 after full undo');
}

# 2. from_string, get_lines, search, save_file & open_file (including overwrite of mmap'd file)
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/sample.pl";

    my $src = "use strict;\nuse warnings;\nsub hello {\n    return 'Hello World';\n}\n";
    my $pt = App::Codit::MT::Core::PieceTable->from_string($src);
    is($pt->to_string, $src, 'from_string exact match');
    is($pt->line_count, 6, 'from_string line_count');

    my $lines = $pt->get_lines(1, 3);
    is_deeply($lines, ['use warnings;', 'sub hello {', "    return 'Hello World';"], 'get_lines(1, 3)');

    my $hits = $pt->search('hello', 0);
    is(scalar(@$hits), 1, 'case-sensitive buffer search finds 1');
    is($hits->[0]{line}, 2, 'hit on 0-based line 2');
    is($hits->[0]{col},  4, 'hit at col 4');

    my $ihits = $pt->search('hello', 1);
    is(scalar(@$ihits), 2, 'case-insensitive buffer search finds 2');

    ok($pt->save_file($path), 'save_file succeeds');
    my $pt2 = App::Codit::MT::Core::PieceTable->open_file($path);
    is($pt2->to_string, $src, 'open_file round-trips saved file');

    # Edit mmap'd file and save back to the SAME path
    ok($pt2->insert(0, "#!/usr/bin/perl\n"), 'insert shebang into mmap piece table');
    ok($pt2->save_file($path), 'atomic save over same mmap path succeeds');

    my $pt3 = App::Codit::MT::Core::PieceTable->open_file($path);
    is($pt3->get_line(0), '#!/usr/bin/perl', 're-opened file has inserted shebang');
    is($pt3->get_line(1), 'use strict;', 'original line 0 shifted to line 1');

    # Empty file open
    my $empty_path = "$dir/empty.txt";
    open my $efh, '>', $empty_path or die $!;
    close $efh;
    my $ept = App::Codit::MT::Core::PieceTable->open_file($empty_path);
    is($ept->byte_length, 0, 'empty file byte_length == 0');
    is($ept->line_count,  1, 'empty file line_count == 1');
}

# 3. 500,000-line file open, random access, edit, undo/redo
{
    my $dir = tempdir(CLEANUP => 1);
    my $big = "$dir/big_500k.pl";
    open my $fh, '>', $big or die "open $big: $!";
    my $chunk = '';
    for my $i (0 .. 999) {
        $chunk .= sprintf("my \$var_%03d = %d; # sample perl line\n", $i, $i * 3);
    }
    for (1 .. 500) {
        print $fh $chunk;
    }
    close $fh;

    my $t0 = time();
    my $pt = App::Codit::MT::Core::PieceTable->open_file($big);
    my $nlines = $pt->line_count;
    my $elapsed_ms = (time() - $t0) * 1000.0;

    diag(sprintf("500,000-line PieceTable mmap open + line index: %.2f ms (%d lines, %.2f MB)",
                 $elapsed_ms, $nlines, $pt->byte_length / (1024 * 1024)));

    is($nlines, 500_001, '500k lines + trailing empty line == 500,001');
    is($pt->get_line(0), 'my $var_000 = 0; # sample perl line', 'line 0 exact');
    is($pt->get_line(250_000), 'my $var_000 = 0; # sample perl line', 'line 250,000 exact');
    is($pt->get_line(499_999), 'my $var_999 = 2997; # sample perl line', 'line 499,999 exact');

    my $off = $pt->line_col_to_offset(250_000, 0);
    my $t_edit0 = time();
    ok($pt->insert($off, "# edited at midpoint\n"), 'insert at line 250,000');
    my $edit_ms = (time() - $t_edit0) * 1000.0;
    diag(sprintf("500,000-line midpoint insert + incremental line index: %.3f ms", $edit_ms));

    is($pt->line_count, 500_002, 'line_count incremented to 500,002');
    is($pt->get_line(250_000), '# edited at midpoint', 'new line at 250,000');
    is($pt->get_line(250_001), 'my $var_000 = 0; # sample perl line', 'old line shifted to 250,001');

    is($pt->undo, 1, 'undo midpoint insert');
    is($pt->line_count, 500_001, 'line_count restored to 500,001');
    is($pt->get_line(250_000), 'my $var_000 = 0; # sample perl line', 'line 250,000 restored');

    is($pt->redo, 1, 'redo midpoint insert');
    is($pt->line_count, 500_002, 'line_count back to 500,002');
}

done_testing();
