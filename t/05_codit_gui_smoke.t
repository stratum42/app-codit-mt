use strict;
use warnings;

use FindBin ();
use File::Spec;
use File::Temp qw(tempfile);
use Cwd qw(abs_path);
use Test::More;

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

if (!eval { require Tcl::Tk::MT; 1 }) {
    plan skip_all => 'Tcl::Tk::MT not available on this Perl build';
}
if ($^O ne 'darwin' && $^O ne 'MSWin32' && !($ENV{DISPLAY} || $ENV{WAYLAND_DISPLAY})) {
    plan skip_all => 'No interactive GUI display available';
}

my $sample_file = File::Spec->catfile($ROOT, 'lib', 'App', 'Codit', 'MT.pm');
my $bin_script  = File::Spec->catfile($ROOT, 'bin', 'codit-mt');

sub _run_cmd {
    my (@cmd) = @_;
    my ($out_fh, $out_file) = tempfile(UNLINK => 1);
    my ($err_fh, $err_file) = tempfile(UNLINK => 1);
    close $out_fh;
    close $err_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $out_file or exit 126;
        open STDERR, '>', $err_file or exit 126;
        exec @cmd;
        exit 127;
    }
    waitpid($pid, 0);
    my $status = $?;

    my $stdout = do { local $/; open my $f, '<', $out_file; <$f> // '' };
    my $stderr = do { local $/; open my $f, '<', $err_file; <$f> // '' };
    return ($status, $stdout, $stderr);
}

my @PERL_INC_ARGS = map { ("-I$_") } grep { !ref($_) && -d $_ } @INC;

# 1. CLI interactive GUI smoke: bin/codit-mt --auto-exit-ms=1000 <sample_file>
{
    my ($status, $stdout, $stderr) = _run_cmd(
        $^X, @PERL_INC_ARGS, $bin_script,
        '--auto-exit-ms=1000',
        $sample_file,
    );
    is($status, 0, 'bin/codit-mt --auto-exit-ms=1000 exited cleanly (status 0)');
    is($stderr, '', 'bin/codit-mt emitted zero warnings/errors on stderr')
        or diag("stderr:\n$stderr");
}

# 2. Live GUI window-size jitter check across dynamic status updates and scrolling
{
    my $probe_code = <<'END_PROBE';
use strict;
use warnings;
use App::Codit::MT;

my ($root, $sample) = @ARGV;
my $app = App::Codit::MT->new(
    engine       => 'gpu',
    backend      => 'auto',
    workspace    => $root,
    auto_exit_ms => 1000,
);
$app->open_file($sample);

my @samples;
my $step = 0;
my $mw = $app->mw;
my $backend = 'none';

my $sampler;
$sampler = sub {
    return unless $mw;
    my $w = int($mw->winfo('width')  || 0);
    my $h = int($mw->winfo('height') || 0);
    push @samples, [$w, $h] if $w > 1 && $h > 1;

    # Vary status bar text lengths and scroll to ensure zero layout jitter
    $step++;
    $app->set_status_field('cursor',   sprintf('Ln %d, Col %d', $step * 123, $step * 7));
    $app->set_status_field('frame_ms', sprintf('%.2f ms', 1.25 + $step * 0.13));
    $app->set_status_field('git',      $step % 2 ? 'git: main' : 'git: feature/very-long-branch');
    if (my $view = $app->active_view) {
        $backend = $view->backend_name // 'none';
        $view->scroll_to_line($step * 15);
        $view->render_frame();
    }
    $app->after(50, $sampler);
};

$app->after(300, $sampler);
$app->run();

my ($min_w, $max_w, $min_h, $max_h) = (999999, 0, 999999, 0);
for my $s (@samples) {
    $min_w = $s->[0] if $s->[0] < $min_w;
    $max_w = $s->[0] if $s->[0] > $max_w;
    $min_h = $s->[1] if $s->[1] < $min_h;
    $max_h = $s->[1] if $s->[1] > $max_h;
}
printf "SAMPLES=%d MIN_W=%d MAX_W=%d MIN_H=%d MAX_H=%d BACKEND=%s\n",
    scalar(@samples), $min_w, $max_w, $min_h, $max_h, $backend;
END_PROBE

    my ($status, $stdout, $stderr) = _run_cmd(
        $^X, @PERL_INC_ARGS, '-e', $probe_code, $ROOT, $sample_file
    );

    is($status, 0, 'GUI jitter probe exited cleanly (status 0)');
    is($stderr, '', 'GUI jitter probe emitted zero warnings/errors')
        or diag("stderr:\n$stderr");

    my %kv = ($stdout =~ /(\w+)=([^\s]+)/g);
    note("GUI probe output: $stdout");

    cmp_ok($kv{SAMPLES} // 0, '>=', 5, 'collected at least 5 geometry samples');
    cmp_ok($kv{MIN_W}   // 0, '>=', 600, 'window width >= 600 px');
    cmp_ok($kv{MIN_H}   // 0, '>=', 400, 'window height >= 400 px');
    ok(defined $kv{MAX_W} && defined $kv{MIN_W} && ($kv{MAX_W} - $kv{MIN_W}) == 0,
        'zero horizontal window-size jitter (delta == 0 px)');
    ok(defined $kv{MAX_H} && defined $kv{MIN_H} && ($kv{MAX_H} - $kv{MIN_H}) == 0,
        'zero vertical window-size jitter (delta == 0 px)');
}

done_testing();
