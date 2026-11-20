use strict;
use warnings;

use FindBin ();
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Time::HiRes qw(time);
use Test::More;

BEGIN {
    my $root = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
    for my $rel (
        File::Spec->catdir('blib', 'arch'),
        File::Spec->catdir('blib', 'lib'),
        'lib',
    ) {
        my $dir = File::Spec->catdir($root, $rel);
        unshift @INC, $dir if -d $dir;
    }

    my $has_tkmt_path = 0;
    for my $inc (@INC) {
        next if ref($inc);
        if (-f File::Spec->catfile($inc, 'Tcl', 'Tk', 'MT.pm')) {
            $has_tkmt_path = 1;
            last;
        }
    }
    if (!$has_tkmt_path) {
        my @candidates;
        push @candidates, $ENV{TCL_TK_MT_DIR}
            if defined $ENV{TCL_TK_MT_DIR} && length $ENV{TCL_TK_MT_DIR};
        push @candidates, File::Spec->catdir($root, File::Spec->updir, 'tcl-tk-mt');
        for my $base (@candidates) {
            my $blib_lib  = File::Spec->catdir($base, 'blib', 'lib');
            my $blib_arch = File::Spec->catdir($base, 'blib', 'arch');
            if (-d $blib_lib) {
                unshift @INC, $blib_arch if -d $blib_arch;
                unshift @INC, $blib_lib;
                last;
            }
        }
    }
}

use App::Codit::MT;
use App::Codit::MT::Core qw(minimap_render_rgba8);
use App::Codit::MT::Document;

my $HAS_TKMT = eval { require Tcl::Tk::MT; 1 } ? 1 : 0;

my $tmpdir = tempdir(CLEANUP => 1);

# Generate a realistic 500,000-line Perl source file.
my $big_lines = 500_000;
my $big_path  = File::Spec->catfile($tmpdir, 'bench_500k.pl');
{
    open my $fh, '>', $big_path or die "open $big_path: $!";
    my @block = (
        "package Bench::Block;\n",
        "sub compute_value {\n",
        "    my (\$self, \$acc) = \@_;\n",
    );
    for my $i (3 .. 98) {
        if ($i % 10 == 0) {
            push @block, "    # comment line $i with Perl tokens\n";
        }
        else {
            push @block, "    my \$v_$i = 'str_$i'; \$acc += $i * length(\$v_$i);\n";
        }
    }
    push @block, "    return \$acc;\n";
    my $block_str = join('', @block); # exactly 100 lines
    for (1 .. ($big_lines / 100)) {
        print {$fh} $block_str;
    }
    close $fh or die "close $big_path: $!";
}

# 1. Headless App::Codit::MT initialization and all 7 built-in plugins
{
    my $app = App::Codit::MT->new(
        headless  => 1,
        workspace => $tmpdir,
        engine    => 'gpu',
        backend   => 'auto',
    );
    isa_ok($app, 'App::Codit::MT', 'headless App::Codit::MT constructed');
    is($app->headless, 1, 'headless flag is true');
    is($app->mw, undef, 'no MainWindow created in headless mode');

    my @expected_plugins = qw(
        FileBrowser
        SearchReplace
        PerlSubs
        Git
        Bookmarks
        Console
        Minimap
    );
    for my $pname (@expected_plugins) {
        my $plug = $app->plugin($pname);
        ok(defined $plug, "plugin '$pname' initialized in headless mode");
        isa_ok($plug, "App::Codit::MT::Plugins::$pname", "plugin '$pname' class");
    }

    $app->shutdown();
    pass('headless app shutdown succeeded');
}

# 2. Document open, syntax lexing, editing, undo/redo, bookmarks, search, minimap on 500k lines
{
    my $t0  = time();
    my $doc = App::Codit::MT::Document->open_file($big_path);
    my $open_ms = (time() - $t0) * 1000.0;

    isa_ok($doc, 'App::Codit::MT::Document', 'Document opened 500k-line file');
    is($doc->language, 'perl', 'auto-detected Perl language');
    cmp_ok($doc->line_count, '>=', $big_lines, "line_count >= $big_lines");
    note(sprintf '500k-line Document::open_file took %.2f ms (%d lines)', $open_ms, $doc->line_count);

    my $toks = $doc->tokenize_range(250_000, 40);
    is(ref($toks), 'ARRAY', 'tokenize_range returns arrayref');
    is(scalar(@$toks), 40, 'tokenize_range returned 40 lines at midpoint');

    # Edit at midpoint + undo/redo
    my $orig_line = $doc->get_line(250_005);
    $doc->goto_line(250_005, 4);
    ok($doc->insert_at_cursor('/*edit*/'), 'insert_at_cursor at line 250,005');
    like($doc->get_line(250_005), qr{\Q/*edit*/\E}, 'edited text present on line 250,005');
    is($doc->dirty, 1, 'document marked dirty after insert');
    is($doc->can_undo, 1, 'can_undo is true');

    ok($doc->undo(), 'undo midpoint insert');
    is($doc->get_line(250_005), $orig_line, 'line restored after undo');
    is($doc->can_redo, 1, 'can_redo is true');

    ok($doc->redo(), 'redo midpoint insert');
    like($doc->get_line(250_005), qr{\Q/*edit*/\E}, 'edited text restored after redo');
    ok($doc->undo(), 'undo back to clean state');
    is($doc->get_line(250_005), $orig_line, 'line matches original after second undo');

    # Bookmarks & git gutter annotations
    $doc->toggle_bookmark(250_005);
    ok($doc->bookmarks->{250_005}, 'bookmark toggled on');
    $doc->toggle_bookmark(250_005);
    ok(!$doc->bookmarks->{250_005}, 'bookmark toggled off');

    $doc->set_git_gutter({ 0 => 'add', 1 => 'mod', 2 => 'del' });
    is($doc->git_gutter->{1}, 'mod', 'git gutter annotation stored');

    # Buffer search
    my $hits = $doc->search_buffer('compute_value', 0, 25);
    is(scalar(@$hits), 25, 'search_buffer respects max_matches cap');

    # Minimap RGBA8888 rendering
    my $rgba = minimap_render_rgba8($doc->pt, $doc->syntax, 80, 200, 250_000, 40);
    is(ref($rgba), 'ARRAY', 'minimap_render_rgba8 returns arrayref');
    is(scalar(@$rgba), 80 * 200 * 4, 'minimap RGBA buffer has expected byte count');
}

# 3. CodeView::GPU (Metal & Software) and CodeView::TkText headless rendering + scrolling
SKIP: {
    skip 'Tcl::Tk::MT not available on this Perl build', 22 unless $HAS_TKMT;

    require App::Codit::MT::CodeView;

    my $doc = App::Codit::MT::Document->open_file($big_path);

    # 3a. CodeView::GPU (auto / Metal on macOS)
    {
        my $scroll_calls = 0;
        my $view = App::Codit::MT::CodeView->new(
            doc       => $doc,
            engine    => 'gpu',
            backend   => 'auto',
            headless  => 1,
            width     => 900,
            height    => 600,
            on_scroll => sub { $scroll_calls++ },
        );
        isa_ok($view, 'App::Codit::MT::CodeView::GPU', 'GPU auto CodeView constructed');
        ok(defined $view->backend_name && length($view->backend_name),
            'GPU auto backend_name is non-empty: ' . ($view->backend_name // 'undef'));

        for my $line (0, 50_000, 150_000, 250_000, 450_000) {
            $view->scroll_to_line($line);
            $view->render_frame();
        }
        is($view->top_line, 450_000, 'GPU auto scrolled to line 450,000');
        cmp_ok($scroll_calls, '>=', 1, 'on_scroll callback invoked');
        cmp_ok($view->last_render_ms, '>=', 0, 'GPU auto last_render_ms recorded');
        note(sprintf 'CodeView::GPU (%s) last_render_ms=%.3f ms',
            $view->backend_name, $view->last_render_ms);

        # Edit + undo/redo while view is attached
        my $before = $doc->get_line(450_001);
        $doc->goto_line(450_001, 0);
        ok($doc->insert_at_cursor('# gpu-edit '), 'insert while GPU view attached');
        $view->render_frame();
        ok($doc->undo(), 'undo while GPU view attached');
        $view->render_frame();
        is($doc->get_line(450_001), $before, 'line restored after undo with GPU view');

        $view->destroy();
    }

    # 3b. CodeView::GPU (Software)
    {
        my $view = App::Codit::MT::CodeView->new(
            doc      => $doc,
            engine   => 'gpu',
            backend  => 'software',
            headless => 1,
            width    => 900,
            height   => 600,
        );
        isa_ok($view, 'App::Codit::MT::CodeView::GPU', 'GPU software CodeView constructed');
        like($view->backend_name, qr/soft/i, 'software backend active: ' . $view->backend_name);

        for my $line (0, 100_000, 300_000) {
            $view->scroll_to_line($line);
            $view->render_frame();
        }
        is($view->top_line, 300_000, 'GPU software scrolled to line 300,000');
        cmp_ok($view->last_render_ms, '>=', 0, 'GPU software last_render_ms recorded');
        note(sprintf 'CodeView::GPU (%s) last_render_ms=%.3f ms',
            $view->backend_name, $view->last_render_ms);

        $view->destroy();
    }

    # 3c. CodeView::TkText (compact Perl file for fast unit-test runtime)
    {
        my $small_src = join('', map { "my \$x_$_ = $_;\n" } (1 .. 500));
        my $small_doc = App::Codit::MT::Document->from_string($small_src, language => 'perl');
        my $view = App::Codit::MT::CodeView->new(
            doc      => $small_doc,
            engine   => 'tktext',
            headless => 1,
            width    => 900,
            height   => 600,
        );
        isa_ok($view, 'App::Codit::MT::CodeView::TkText', 'TkText CodeView constructed');
        is($view->engine_name, 'tktext', 'TkText engine_name is tktext');

        for my $line (0, 100, 250, 400) {
            $view->scroll_to_line($line);
            $view->render_frame();
        }
        is($view->top_line, 400, 'TkText scrolled to line 400');

        my $before = $small_doc->get_line(400);
        $small_doc->goto_line(400, 0);
        ok($small_doc->insert_at_cursor('# tk-edit '), 'insert while TkText view attached');
        ok($small_doc->undo(), 'undo while TkText view attached');
        is($small_doc->get_line(400), $before, 'line restored after undo with TkText view');

        $view->destroy();
    }

    # 3d. App::Codit::MT::run_headless_bench end-to-end on the 500k-line file
    {
        my $app = App::Codit::MT->new(
            headless  => 1,
            workspace => $tmpdir,
            engine    => 'gpu',
            backend   => 'auto',
        );
        my $res = $app->run_headless_bench(file => $big_path, frames => 20);
        is(ref($res), 'HASH', 'run_headless_bench returned hashref');
        cmp_ok($res->{lines}, '>=', $big_lines, 'headless bench opened 500k-line file');
        is($res->{frames}, 20, 'headless bench rendered 20 frames');
        cmp_ok($res->{fps}, '>', 0, 'headless bench reported positive FPS');
        $app->shutdown();
    }
}

done_testing();
