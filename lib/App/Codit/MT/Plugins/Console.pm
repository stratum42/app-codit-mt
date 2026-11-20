package App::Codit::MT::Plugins::Console;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use IO::Select ();
use POSIX qw(WNOHANG);

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugins::Console - Non-blocking command and script runner console

=head1 SYNOPSIS

    my $console = App::Codit::MT::Plugins::Console->new();
    $console->init($app);
    $console->run_current_file();

=head1 DESCRIPTION

Adds a bottom-dock output console to L<App::Codit::MT> with an interactive
command entry bar, a C<Run Current File (F5)> action, and non-blocking piped
process polling via Tk C<after> timers so the editor remains responsive.

=cut

sub name { 'Console' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{cmd_text}  = '';
    $self->{pid}       = undef;
    $self->{fh}        = undef;
    $self->{select}    = undef;
    $self->{poll_job}  = undef;
    $self->{history}   = [];

    return if $app->headless || !$app->bottom_dock;

    my $dock  = $app->bottom_dock;
    my $theme = $app->theme || {};
    my $bg    = $theme->{bg}       || '#0f111a';
    my $fg    = $theme->{fg}       || '#d6deeb';
    my $muted = $theme->{fg_muted} || '#7e89a8';
    my $green = $theme->{green}    || '#3fb950';
    my $red   = $theme->{red}      || '#f85149';

    my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
    $self->{frame} = $frame;

    # Command bar
    my $bar = $frame->ttkFrame(-style => 'Dark.TFrame');
    $bar->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => 3);

    my $lbl = $bar->ttkLabel(-style => 'Dark.TLabel', -text => '$');
    $lbl->pack(-side => 'left', -padx => [2, 4]);

    my $entry = $bar->ttkEntry(
        -style        => 'Dark.TEntry',
        -textvariable => \$self->{cmd_text},
    );
    $entry->pack(-side => 'left', -fill => 'x', -expand => 1, -padx => [0, 4]);
    $entry->bind('<Return>', sub { $self->run_entry() });
    $self->{cmd_entry} = $entry;

    my $run_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Run',
        -width   => 5,
        -command => sub { $self->run_entry() },
    );
    $run_btn->pack(-side => 'left', -padx => [0, 3]);

    my $run_file_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Run File (F5)',
        -width   => 12,
        -command => sub { $self->run_current_file() },
    );
    $run_file_btn->pack(-side => 'left', -padx => [0, 3]);

    my $stop_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Stop',
        -width   => 5,
        -command => sub { $self->stop() },
    );
    $stop_btn->pack(-side => 'left', -padx => [0, 3]);

    my $clear_btn = $bar->ttkButton(
        -style   => 'Dark.TButton',
        -text    => 'Clear',
        -width   => 5,
        -command => sub { $self->clear() },
    );
    $clear_btn->pack(-side => 'left');

    # Output area
    my $out_wrap = $frame->ttkFrame(-style => 'Dark.TFrame');
    $out_wrap->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 4, -pady => [0, 4]);

    my $text = $out_wrap->Text(
        -background        => $bg,
        -foreground        => $fg,
        -insertbackground  => $fg,
        -selectbackground  => '#2a3554',
        -font              => 'TkFixedFont',
        -borderwidth       => 0,
        -highlightthickness => 0,
        -wrap              => 'word',
        -height            => 8,
        -state             => 'disabled',
    );
    my $vsb = $out_wrap->ttkScrollbar(
        -style   => 'Dark.Vertical.TScrollbar',
        -orient  => 'vertical',
        -command => "$text yview",
    );
    $text->configure(-yscrollcommand => "$vsb set");

    $text->tag('configure', 'cmd', -foreground => $muted);
    $text->tag('configure', 'ok',  -foreground => $green);
    $text->tag('configure', 'err', -foreground => $red);

    $vsb->pack(-side => 'right', -fill => 'y');
    $text->pack(-side => 'left', -fill => 'both', -expand => 1);
    $self->{output} = $text;

    $app->add_bottom_tab('Console', $frame);
    return $self;
}

sub run_entry {
    my ($self) = @_;
    my $cmd = $self->{cmd_text};
    return unless defined $cmd;
    $cmd =~ s/\A\s+|\s+\z//g;
    return unless length $cmd;
    push @{ $self->{history} }, $cmd;
    $self->run_command($cmd);
}

sub run_current_file {
    my ($self) = @_;
    my $app = $self->app or return;
    my $doc = $app->active_doc;
    unless ($doc && defined $doc->path && length $doc->path) {
        $self->append_output("[Console] No saved file is active.\n", 'err');
        $app->select_bottom_tab($self->{frame}) if $self->{frame};
        return;
    }

    my $path = $doc->path;
    my $lang = $doc->can('language') ? ($doc->language // '') : '';
    my $dir  = dirname($path);

    my @argv;
    if ($lang eq 'perl' || $path =~ /\.(?:pl|pm|t)\z/i) {
        @argv = ($^X, $path);
    }
    elsif ($lang eq 'python' || $path =~ /\.py\z/i) {
        @argv = ('python3', $path);
    }
    elsif ($lang eq 'shell' || $path =~ /\.(?:sh|bash|zsh)\z/i) {
        @argv = ('sh', $path);
    }
    elsif (-x $path) {
        @argv = ($path);
    }
    else {
        @argv = ($^X, $path);
    }

    $self->run_command(\@argv, $dir);
}

sub run_command {
    my ($self, $cmd, $cwd) = @_;
    my $app = $self->app or return;

    $self->stop();
    $app->select_bottom_tab($self->{frame}) if $self->{frame};

    my $display = ref($cmd) eq 'ARRAY' ? join(' ', @$cmd) : "$cmd";
    $self->append_output("\$ $display\n", 'cmd');

    return if $app->headless;

    my $work_dir = (defined $cwd && -d $cwd) ? $cwd : ($app->workspace // getcwd());

    my ($r_fh, $w_fh);
    unless (pipe($r_fh, $w_fh)) {
        $self->append_output("[Console] pipe() failed: $!\n", 'err');
        return;
    }

    my $pid = fork();
    if (!defined $pid) {
        close $r_fh;
        close $w_fh;
        $self->append_output("[Console] fork() failed: $!\n", 'err');
        return;
    }

    if ($pid == 0) {
        close $r_fh;
        open(STDOUT, '>&', $w_fh) or POSIX::_exit(127);
        open(STDERR, '>&', $w_fh) or POSIX::_exit(127);
        close $w_fh;
        chdir($work_dir) if defined $work_dir && -d $work_dir;
        if (ref($cmd) eq 'ARRAY') {
            exec { $cmd->[0] } @$cmd;
        }
        else {
            exec('/bin/sh', '-c', $cmd);
        }
        print STDERR "exec failed: $!\n";
        POSIX::_exit(127);
    }

    close $w_fh;
    binmode($r_fh, ':raw');

    $self->{pid}    = $pid;
    $self->{fh}     = $r_fh;
    $self->{select} = IO::Select->new($r_fh);
    $self->_schedule_poll();
}

sub _schedule_poll {
    my ($self) = @_;
    my $app = $self->app or return;
    $self->{poll_job} = $app->after(25, sub { $self->_poll_output() });
}

sub _poll_output {
    my ($self) = @_;
    $self->{poll_job} = undef;
    my $fh  = $self->{fh} or return;
    my $sel = $self->{select};

    my $eof = 0;
    if ($sel) {
        for (1 .. 16) {
            my @ready = $sel->can_read(0);
            last unless @ready;
            my $buf = '';
            my $n   = sysread($fh, $buf, 8192);
            if (defined $n && $n > 0) {
                $self->append_output($buf);
            }
            else {
                $eof = 1;
                last;
            }
        }
    }

    if ($eof) {
        $self->_finish_process();
        return;
    }

    if (defined $self->{pid}) {
        my $done = waitpid($self->{pid}, WNOHANG);
        if ($done > 0 || $done < 0) {
            my $status = $?;
            # Drain remaining buffered bytes
            while ($sel && $sel->can_read(0)) {
                my $buf = '';
                my $n   = sysread($fh, $buf, 8192);
                last unless defined $n && $n > 0;
                $self->append_output($buf);
            }
            $self->_finish_process($status);
            return;
        }
    }

    $self->_schedule_poll();
}

sub _finish_process {
    my ($self, $status) = @_;
    if (defined $self->{fh}) {
        close $self->{fh};
        $self->{fh} = undef;
    }
    $self->{select} = undef;

    if (defined $self->{pid}) {
        if (!defined $status) {
            waitpid($self->{pid}, 0);
            $status = $?;
        }
        $self->{pid} = undef;
        my $code = $status >> 8;
        my $tag  = ($code == 0) ? 'ok' : 'err';
        $self->append_output("[exited with status $code]\n\n", $tag);
    }
}

sub stop {
    my ($self) = @_;
    my $app = $self->app;
    if ($app && defined $self->{poll_job}) {
        $app->after_cancel($self->{poll_job});
        $self->{poll_job} = undef;
    }
    if (defined $self->{pid}) {
        kill('TERM', $self->{pid});
        waitpid($self->{pid}, WNOHANG);
        $self->{pid} = undef;
        $self->append_output("[process terminated]\n", 'err');
    }
    if (defined $self->{fh}) {
        close $self->{fh};
        $self->{fh} = undef;
    }
    $self->{select} = undef;
}

sub clear {
    my ($self) = @_;
    my $text = $self->{output} or return;
    $text->configure(-state => 'normal');
    $text->delete('1.0', 'end');
    $text->configure(-state => 'disabled');
}

sub append_output {
    my ($self, $str, $tag) = @_;
    return unless defined $str && length $str;
    my $text = $self->{output} or return;
    $text->configure(-state => 'normal');
    if (defined $tag && length $tag) {
        $text->insert('end', $str, $tag);
    }
    else {
        $text->insert('end', $str);
    }
    $text->see('end');
    $text->configure(-state => 'disabled');
}

sub shutdown {
    my ($self) = @_;
    $self->stop();
}

1;
