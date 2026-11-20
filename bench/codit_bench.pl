#!/usr/bin/env perl
use strict;
use warnings;

use FindBin ();
use File::Spec;
use File::Temp qw(tempdir tempfile);
use File::Find qw(find);
use Cwd qw(abs_path);
use Time::HiRes qw(time);
use Getopt::Long qw(:config no_ignore_case bundling);

my $ROOT;
my @EXTRA_INC;

BEGIN {
    $ROOT = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
    for my $rel (
        File::Spec->catdir('blib', 'arch'),
        File::Spec->catdir('blib', 'lib'),
        'lib',
    ) {
        my $dir = File::Spec->catdir($ROOT, $rel);
        if (-d $dir) {
            unshift @INC, $dir;
            push @EXTRA_INC, $dir;
        }
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
        push @candidates, File::Spec->catdir($ROOT, File::Spec->updir, 'tcl-tk-mt');
        for my $base (@candidates) {
            my $blib_lib  = File::Spec->catdir($base, 'blib', 'lib');
            my $blib_arch = File::Spec->catdir($base, 'blib', 'arch');
            if (-d $blib_lib) {
                if (-d $blib_arch) {
                    unshift @INC, $blib_arch;
                    push @EXTRA_INC, $blib_arch;
                }
                unshift @INC, $blib_lib;
                push @EXTRA_INC, $blib_lib;
                last;
            }
        }
    }
}

use App::Codit::MT;
use App::Codit::MT::Core qw(search_dir is_perl5_mt);
use App::Codit::MT::Document;
use App::Codit::MT::CodeView;

my $num_lines    = 500_000;
my $scroll_frames = 120;
my $tk_frames    = 60;
my $typing_steps = 50;
my $search_dir_opt;
my $search_query = 'Perl_croak';
my $json_out     = 0;

GetOptions(
    'lines=i'       => \$num_lines,
    'frames=i'      => \$scroll_frames,
    'tk-frames=i'   => \$tk_frames,
    'typing=i'      => \$typing_steps,
    'search-dir=s'  => \$search_dir_opt,
    'query=s'       => \$search_query,
    'json!'         => \$json_out,
) or die "Usage: $0 [--lines=500000] [--frames=120] [--search-dir=DIR] [--query=STR] [--json]\n";

# Resolve default search target directory
if (!defined $search_dir_opt) {
    for my $cand (
        File::Spec->catdir($ROOT, File::Spec->updir, 'perl5-mt'),
        File::Spec->catdir($ROOT, File::Spec->updir, 'tcl-tk-mt'),
        $ROOT,
    ) {
        if (-d $cand) {
            $search_dir_opt = abs_path($cand);
            last;
        }
    }
}
if ($search_dir_opt =~ /tcl-tk-mt/ && $search_query eq 'Perl_croak') {
    $search_query = 'tkmt_';
}

my $tmpdir   = tempdir(CLEANUP => 1);
my $big_path = File::Spec->catfile($tmpdir, "bench_${num_lines}.pl");

sub _generate_perl_file {
    my ($path, $lines) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    my @block = (
        "package Bench::Block;\n",
        "sub compute_value {\n",
        "    my (\$self, \$acc) = \@_;\n",
    );
    for my $i (3 .. 98) {
        if ($i % 10 == 0) {
            push @block, "    # comment line $i with Perl tokens and numbers 12345\n";
        }
        else {
            push @block, "    my \$v_$i = 'str_$i'; \$acc += $i * length(\$v_$i);\n";
        }
    }
    push @block, "    return \$acc;\n";
    my $block_str = join('', @block); # 100 lines
    my $reps = int($lines / 100);
    for (1 .. $reps) {
        print {$fh} $block_str;
    }
    close $fh or die "close $path: $!";
    return (-s $path) || 0;
}

sub _percentile {
    my ($sorted_ref, $p) = @_;
    return 0.0 unless @$sorted_ref;
    my $idx = int(($p / 100.0) * (@$sorted_ref - 1) + 0.5);
    $idx = 0 if $idx < 0;
    $idx = $#$sorted_ref if $idx > $#$sorted_ref;
    return $sorted_ref->[$idx];
}

sub _run_perl_child {
    my ($env_ref, @args) = @_;
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);
    close $out_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        if ($env_ref) {
            for my $k (keys %$env_ref) {
                if (defined $env_ref->{$k}) {
                    $ENV{$k} = $env_ref->{$k};
                }
                else {
                    delete $ENV{$k};
                }
            }
        }
        open STDOUT, '>', $out_file or exit 126;
        open STDERR, '>', File::Spec->devnull() or exit 126;
        exec($^X, @args);
        exit 127;
    }
    waitpid($pid, 0);
    my $status = $?;
    my $stdout = do { local $/; open my $f, '<', $out_file; <$f> // '' };
    return ($status, $stdout);
}

sub _pure_perl_search_dir {
    my ($root, $query, $max_matches) = @_;
    $max_matches ||= 50_000;
    my $count = 0;
    my %skip_dir = map { $_ => 1 } ('.git', 'blib', 'node_modules', '_build', '.svn');
    my $qlen = length($query);
    return 0 unless $qlen;

    find(
        {
            no_chdir   => 1,
            preprocess => sub {
                return grep { !$skip_dir{$_} } @_;
            },
            wanted => sub {
                return if $count >= $max_matches;
                return unless -f $_ && !-l $_;
                my $sz = -s $_;
                return if !$sz || $sz > 16 * 1024 * 1024;
                open my $fh, '<:raw', $_ or return;
                my $head;
                my $nread = read($fh, $head, 4096);
                if (!$nread || index($head, "\0") >= 0) {
                    close $fh;
                    return;
                }
                seek($fh, 0, 0);
                while (my $line = <$fh>) {
                    my $pos = 0;
                    while ((my $idx = index($line, $query, $pos)) >= 0) {
                        $count++;
                        last if $count >= $max_matches;
                        $pos = $idx + $qlen;
                    }
                    last if $count >= $max_matches;
                }
                close $fh;
            },
        },
        $root,
    );
    return $count;
}

my $file_bytes = _generate_perl_file($big_path, $num_lines);
my $file_mb    = $file_bytes / (1024.0 * 1024.0);

my %results = (
    perl_version => sprintf('%vd', $^V),
    is_perl5_mt  => is_perl5_mt() ? 1 : 0,
    file_lines   => $num_lines,
    file_mb      => sprintf('%.2f', $file_mb) + 0,
);

my @inc_args = map { ("-I$_") } grep { !ref($_) && -d $_ } @INC;

# ---------------------------------------------------------------------------
# 1. Cold startup time (ms) & RSS memory (MB)
# ---------------------------------------------------------------------------
{
    my $sample_file = File::Spec->catfile($ROOT, 'lib', 'App', 'Codit', 'MT.pm');
    my $probe = <<'END_STARTUP';
use strict;
use warnings;
use App::Codit::MT;
my ($ws, $file) = @ARGV;
my $app = App::Codit::MT->new(headless => 1, workspace => $ws, engine => 'gpu', backend => 'auto');
$app->open_file($file);
my $rss_kb = `ps -o rss= -p $$`;
$rss_kb =~ s/\s+//g if defined $rss_kb;
$app->shutdown();
print "RSS_KB=", ($rss_kb || 0), "\n";
END_STARTUP

    my @cold_ms;
    my $rss_mb = 0.0;
    for (1 .. 3) {
        my $t0 = time();
        my ($st, $out) = _run_perl_child(undef, @inc_args, '-e', $probe, $ROOT, $sample_file);
        my $dt = (time() - $t0) * 1000.0;
        die "startup probe failed (status=$st)" if $st != 0;
        push @cold_ms, $dt;
        if ($out =~ /RSS_KB=(\d+)/) {
            $rss_mb = $1 / 1024.0;
        }
    }
    @cold_ms = sort { $a <=> $b } @cold_ms;
    $results{cold_startup_ms} = sprintf('%.2f', $cold_ms[1]) + 0;
    $results{rss_mb}          = sprintf('%.2f', $rss_mb) + 0;
}

# ---------------------------------------------------------------------------
# 2. 500,000-line file open: PieceTable vs Native Tk::Text
# ---------------------------------------------------------------------------
my $doc;
{
    my @pt_times;
    for (1 .. 3) {
        my $t0 = time();
        my $d  = App::Codit::MT::Document->open_file($big_path);
        my $dt = (time() - $t0) * 1000.0;
        push @pt_times, $dt;
        $doc = $d;
    }
    @pt_times = sort { $a <=> $b } @pt_times;
    $results{open_piecetable_ms} = sprintf('%.2f', $pt_times[1]) + 0;
}

# ---------------------------------------------------------------------------
# 3. 500,000-line smooth scroll FPS & p50/p95: GPU Metal vs GPU Software vs TkText
# ---------------------------------------------------------------------------
sub _bench_scroll_gpu {
    my ($doc_obj, $backend, $frames) = @_;
    my $view = App::Codit::MT::CodeView->new(
        doc      => $doc_obj,
        engine   => 'gpu',
        backend  => $backend,
        headless => 1,
        width    => 1000,
        height   => 700,
    );
    my $bname = $view->backend_name // $backend;
    my $max_line = $doc_obj->line_count - 50;
    $max_line = 1 if $max_line < 1;

    # Warmup
    for my $w (0 .. 9) {
        $view->scroll_to_line($w * 500);
        $view->render_frame();
    }

    my @ft;
    my $step = int($max_line / ($frames || 1));
    $step = 1 if $step < 1;
    my $t_all = time();
    for my $i (0 .. $frames - 1) {
        my $line = ($i * $step) % $max_line;
        my $t0 = time();
        $view->scroll_to_line($line);
        $view->render_frame();
        push @ft, (time() - $t0) * 1000.0;
    }
    my $elapsed = time() - $t_all;
    my @sorted  = sort { $a <=> $b } @ft;
    my $fps     = $elapsed > 0 ? ($frames / $elapsed) : 0.0;
    $view->destroy();

    return {
        backend => $bname,
        frames  => $frames,
        fps     => sprintf('%.1f', $fps) + 0,
        p50_ms  => sprintf('%.3f', _percentile(\@sorted, 50)) + 0,
        p95_ms  => sprintf('%.3f', _percentile(\@sorted, 95)) + 0,
    };
}

$results{scroll_gpu_metal} = _bench_scroll_gpu($doc, 'auto',     $scroll_frames);
$results{scroll_gpu_sw}    = _bench_scroll_gpu($doc, 'software', $scroll_frames);

# Native Tk::Text load + scroll on the exact same 500,000-line file
{
    my $t0 = time();
    my $tk_view = App::Codit::MT::CodeView->new(
        doc      => $doc,
        engine   => 'tktext',
        headless => 1,
        width    => 1000,
        height   => 700,
    );
    my $tk_load_ms = (time() - $t0) * 1000.0;
    $results{open_tktext_ms} = sprintf('%.2f', $tk_load_ms) + 0;
    $results{open_speedup}   = sprintf('%.1f',
        $results{open_piecetable_ms} > 0 ? ($tk_load_ms / $results{open_piecetable_ms}) : 0) + 0;

    my $max_line = $doc->line_count - 50;
    $max_line = 1 if $max_line < 1;

    # Warmup
    for my $w (0 .. 4) {
        $tk_view->scroll_to_line($w * 500);
        $tk_view->render_frame();
    }

    my @ft;
    my $step = int($max_line / ($tk_frames || 1));
    $step = 1 if $step < 1;
    my $t_all = time();
    for my $i (0 .. $tk_frames - 1) {
        my $line = ($i * $step) % $max_line;
        my $tf0  = time();
        $tk_view->scroll_to_line($line);
        $tk_view->render_frame();
        push @ft, (time() - $tf0) * 1000.0;
    }
    my $elapsed = time() - $t_all;
    my @sorted  = sort { $a <=> $b } @ft;
    my $fps     = $elapsed > 0 ? ($tk_frames / $elapsed) : 0.0;
    $tk_view->destroy();

    $results{scroll_tktext} = {
        backend => 'tktext',
        frames  => $tk_frames,
        fps     => sprintf('%.1f', $fps) + 0,
        p50_ms  => sprintf('%.3f', _percentile(\@sorted, 50)) + 0,
        p95_ms  => sprintf('%.3f', _percentile(\@sorted, 95)) + 0,
    };
}

# ---------------------------------------------------------------------------
# 4. Incremental typing latency inside a 500,000-line file
# ---------------------------------------------------------------------------
{
    my $edit_doc = App::Codit::MT::Document->open_file($big_path);
    my $mid_line = int($num_lines / 2);

    # 4a. Core edit + incremental syntax re-lex (without GPU frame)
    $edit_doc->goto_line($mid_line, 4);
    my @core_lat;
    for my $i (1 .. $typing_steps) {
        my $t0 = time();
        $edit_doc->insert_at_cursor('x');
        $edit_doc->tokenize_range($mid_line, 40);
        push @core_lat, (time() - $t0) * 1000.0;
    }
    my @core_sorted = sort { $a <=> $b } @core_lat;
    $results{typing_core_p50_ms} = sprintf('%.3f', _percentile(\@core_sorted, 50)) + 0;
    $results{typing_core_p95_ms} = sprintf('%.3f', _percentile(\@core_sorted, 95)) + 0;

    # 4b. Full interactive keystroke: edit + syntax re-lex + GPU Metal frame render
    my $gpu_view = App::Codit::MT::CodeView->new(
        doc      => $edit_doc,
        engine   => 'gpu',
        backend  => 'auto',
        headless => 1,
        width    => 1000,
        height   => 700,
    );
    $gpu_view->scroll_to_line($mid_line - 10);
    $gpu_view->render_frame(); # warmup

    my @full_lat;
    for my $i (1 .. $typing_steps) {
        my $t0 = time();
        $edit_doc->insert_at_cursor('y'); # triggers CodeView::GPU render via on_change/on_cursor
        push @full_lat, (time() - $t0) * 1000.0;
    }
    my @full_sorted = sort { $a <=> $b } @full_lat;
    $results{typing_gpu_p50_ms} = sprintf('%.3f', _percentile(\@full_sorted, 50)) + 0;
    $results{typing_gpu_p95_ms} = sprintf('%.3f', _percentile(\@full_sorted, 95)) + 0;
    $gpu_view->destroy();
}

# ---------------------------------------------------------------------------
# 5. Parallel project-wide search: MT vs PERL_FORCE_SCALAR=1 vs Pure Perl
# ---------------------------------------------------------------------------
{
    # Warm OS page cache once
    my $warm = search_dir($search_dir_opt, $search_query, 0, 50_000);

    # 5a. Multi-threaded C11 search_dir (median of 3 runs)
    my @mt_times;
    my $mt_count = 0;
    for (1 .. 3) {
        my $t0 = time();
        my $m  = search_dir($search_dir_opt, $search_query, 0, 50_000);
        push @mt_times, (time() - $t0) * 1000.0;
        $mt_count = scalar(@$m);
    }
    @mt_times = sort { $a <=> $b } @mt_times;

    # 5b. Single-threaded C11 search_dir (PERL_FORCE_SCALAR=1 in child process)
    my $scalar_probe = <<'END_SCALAR';
use strict;
use warnings;
use Time::HiRes qw(time);
use App::Codit::MT::Core qw(search_dir force_scalar);
my ($dir, $q) = @ARGV;
my @times;
my $cnt = 0;
for (1 .. 3) {
    my $t0 = time();
    my $m  = search_dir($dir, $q, 0, 50_000);
    push @times, (time() - $t0) * 1000.0;
    $cnt = scalar(@$m);
}
@times = sort { $a <=> $b } @times;
printf "COUNT=%d MS=%.2f SCALAR=%d\n", $cnt, $times[1], force_scalar();
END_SCALAR

    my ($st, $out) = _run_perl_child(
        { PERL_FORCE_SCALAR => '1' },
        @inc_args, '-e', $scalar_probe, $search_dir_opt, $search_query,
    );
    die "scalar search probe failed (status=$st)" if $st != 0;
    my %skv = ($out =~ /(\w+)=([^\s]+)/g);
    my $scalar_ms    = ($skv{MS}    // 0) + 0;
    my $scalar_count = ($skv{COUNT} // 0) + 0;

    # 5c. Pure-Perl recursive grep
    my $t_pp = time();
    my $pp_count = _pure_perl_search_dir($search_dir_opt, $search_query, 50_000);
    my $pp_ms    = (time() - $t_pp) * 1000.0;

    $results{search} = {
        target_dir       => $search_dir_opt,
        query            => $search_query,
        mt_ms            => sprintf('%.2f', $mt_times[1]) + 0,
        mt_matches       => $mt_count,
        scalar_ms        => sprintf('%.2f', $scalar_ms) + 0,
        scalar_matches   => $scalar_count,
        pure_perl_ms     => sprintf('%.2f', $pp_ms) + 0,
        pure_perl_matches => $pp_count,
        speedup_vs_scalar => sprintf('%.2f', $mt_times[1] > 0 ? ($scalar_ms / $mt_times[1]) : 0) + 0,
        speedup_vs_perl   => sprintf('%.1f', $mt_times[1] > 0 ? ($pp_ms / $mt_times[1]) : 0) + 0,
    };
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($json_out) {
    print _encode_json(\%results), "\n";
    exit 0;
}

print "=== App::Codit::MT Benchmark ===\n";
printf "Perl: %s (perl5-mt=%d) | File: %d lines (%.2f MB)\n\n",
    $results{perl_version}, $results{is_perl5_mt}, $results{file_lines}, $results{file_mb};

printf "1. Startup & Memory:\n";
printf "   Cold startup (headless + 7 plugins): %8.2f ms\n", $results{cold_startup_ms};
printf "   Resident memory (RSS):               %8.2f MB\n\n", $results{rss_mb};

printf "2. %d-Line Perl File Open:\n", $num_lines;
printf "   PieceTable (mmap + line index):      %8.2f ms\n", $results{open_piecetable_ms};
printf "   Native Tk::Text full load:           %8.2f ms  (%.1fx slower)\n\n",
    $results{open_tktext_ms}, $results{open_speedup};

printf "3. %d-Line Smooth Scroll (%d GPU frames / %d TkText frames):\n",
    $num_lines, $scroll_frames, $tk_frames;
printf "   %-28s %8s %10s %10s\n", 'Engine / Backend', 'FPS', 'p50 (ms)', 'p95 (ms)';
printf "   %-28s %8.1f %10.3f %10.3f\n",
    "CodeView::GPU ($results{scroll_gpu_metal}{backend})",
    $results{scroll_gpu_metal}{fps}, $results{scroll_gpu_metal}{p50_ms}, $results{scroll_gpu_metal}{p95_ms};
printf "   %-28s %8.1f %10.3f %10.3f\n",
    "CodeView::GPU ($results{scroll_gpu_sw}{backend})",
    $results{scroll_gpu_sw}{fps}, $results{scroll_gpu_sw}{p50_ms}, $results{scroll_gpu_sw}{p95_ms};
printf "   %-28s %8.1f %10.3f %10.3f\n\n",
    "CodeView::TkText",
    $results{scroll_tktext}{fps}, $results{scroll_tktext}{p50_ms}, $results{scroll_tktext}{p95_ms};

printf "4. Incremental Typing Latency at Line %d (%d keystrokes):\n",
    int($num_lines / 2), $typing_steps;
printf "   Core edit + syntax re-lex:           p50 = %6.3f ms, p95 = %6.3f ms\n",
    $results{typing_core_p50_ms}, $results{typing_core_p95_ms};
printf "   Edit + syntax + GPU Metal frame:     p50 = %6.3f ms, p95 = %6.3f ms\n\n",
    $results{typing_gpu_p50_ms}, $results{typing_gpu_p95_ms};

my $s = $results{search};
printf "5. Project-Wide Search (%s, query='%s'):\n", $s->{target_dir}, $s->{query};
printf "   Core::search_dir (multi-threaded):   %8.2f ms  (%d matches)\n",
    $s->{mt_ms}, $s->{mt_matches};
printf "   Core::search_dir (PERL_FORCE_SCALAR):%8.2f ms  (%d matches, %.2fx vs MT)\n",
    $s->{scalar_ms}, $s->{scalar_matches}, $s->{speedup_vs_scalar};
printf "   Pure-Perl recursive grep:            %8.2f ms  (%d matches, %.1fx vs MT)\n",
    $s->{pure_perl_ms}, $s->{pure_perl_matches}, $s->{speedup_vs_perl};

exit 0;

sub _encode_json {
    my ($val) = @_;
    return 'null' unless defined $val;
    if (ref($val) eq 'HASH') {
        my @pairs;
        for my $k (sort keys %$val) {
            push @pairs, _json_str($k) . ':' . _encode_json($val->{$k});
        }
        return '{' . join(',', @pairs) . '}';
    }
    if (ref($val) eq 'ARRAY') {
        return '[' . join(',', map { _encode_json($_) } @$val) . ']';
    }
    if ($val =~ /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/) {
        return $val;
    }
    return _json_str($val);
}

sub _json_str {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return '"' . $s . '"';
}
