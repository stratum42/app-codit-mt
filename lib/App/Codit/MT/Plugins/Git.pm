package App::Codit::MT::Plugins::Git;

use strict;
use warnings;
use parent 'App::Codit::MT::Plugin';

use File::Spec ();
use IO::Select ();
use POSIX qw(WNOHANG);

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugins::Git - Non-blocking Git status, branch, gutter diff, and diff viewer plugin

=head1 SYNOPSIS

    my $git = App::Codit::MT::Plugins::Git->new();
    $git->init($app);

=head1 DESCRIPTION

Integrates Git with L<App::Codit::MT> using non-blocking subprocess polling:
detects repository root and branch via C<git rev-parse>, populates a left-dock
changed-files list via C<git status --porcelain>, updates the status bar branch
indicator, computes 0-based inline gutter diff markers (C<add>/C<mod>/C<del>)
for the active document via C<git diff -U0>, and displays syntax-colored diffs
in a bottom-dock viewer. Becomes a no-op outside a Git repository.

=cut

sub name { 'Git' }

sub init {
    my ($self, $app) = @_;
    $self->SUPER::init($app);

    $self->{repo_root}     = undef;
    $self->{branch}        = undef;
    $self->{changed_files} = [];
    $self->{node_path}     = {};
    $self->{jobs}          = {};
    $self->{job_seq}       = 0;
    $self->{seq}           = 0;

    return if $app->headless;

    if ($app->left_dock) {
        my $dock  = $app->left_dock;
        my $frame = $dock->ttkFrame(-style => 'Dark.TFrame');
        $self->{left_frame} = $frame;

        my $bar = $frame->ttkFrame(-style => 'Dark.TFrame');
        $bar->pack(-side => 'top', -fill => 'x', -padx => 4, -pady => 4);

        $self->{branch_text} = 'No Git Repo';
        my $lbl = $bar->ttkLabel(
            -style        => 'Dark.TLabel',
            -textvariable => \$self->{branch_text},
        );
        $lbl->pack(-side => 'left');

        my $btn = $bar->ttkButton(
            -style   => 'Dark.TButton',
            -text    => 'Refresh',
            -width   => 7,
            -command => sub { $self->refresh() },
        );
        $btn->pack(-side => 'right');

        my $wrap = $frame->ttkFrame(-style => 'Dark.TFrame');
        $wrap->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 4, -pady => [0, 4]);

        my $tree = $wrap->ttkTreeview(
            -style      => 'Dark.Treeview',
            -show       => 'tree',
            -selectmode => 'browse',
        );
        my $vsb = $wrap->ttkScrollbar(
            -style   => 'Dark.Vertical.TScrollbar',
            -orient  => 'vertical',
            -command => "$tree yview",
        );
        $tree->configure(-yscrollcommand => "$vsb set");

        $vsb->pack(-side => 'right', -fill => 'y');
        $tree->pack(-side => 'left', -fill => 'both', -expand => 1);
        $self->{tree} = $tree;

        $tree->bind('<<TreeviewSelect>>', sub { $self->_on_select_file() });
        $tree->bind('<Double-1>',         sub { $self->_on_open_file() });
        $tree->bind('<Return>',           sub { $self->_on_open_file() });

        $app->add_left_tab('Git', $frame);
    }

    if ($app->bottom_dock) {
        my $bdock = $app->bottom_dock;
        my $theme = $app->theme || {};
        my $bg    = $theme->{bg}     || '#0f111a';
        my $fg    = $theme->{fg}     || '#d6deeb';
        my $green = $theme->{green}  || '#3fb950';
        my $red   = $theme->{red}    || '#f85149';
        my $accent = $theme->{accent} || '#58a6ff';

        my $dframe = $bdock->ttkFrame(-style => 'Dark.TFrame');
        $self->{diff_frame} = $dframe;

        my $text = $dframe->Text(
            -background         => $bg,
            -foreground         => $fg,
            -font               => 'TkFixedFont',
            -borderwidth        => 0,
            -highlightthickness => 0,
            -wrap               => 'none',
            -height             => 8,
            -state              => 'disabled',
        );
        my $vsb = $dframe->ttkScrollbar(
            -style   => 'Dark.Vertical.TScrollbar',
            -orient  => 'vertical',
            -command => "$text yview",
        );
        $text->configure(-yscrollcommand => "$vsb set");

        $text->tag('configure', 'add',  -foreground => $green);
        $text->tag('configure', 'del',  -foreground => $red);
        $text->tag('configure', 'hunk', -foreground => $accent);

        $vsb->pack(-side => 'right', -fill => 'y');
        $text->pack(-side => 'left', -fill => 'both', -expand => 1);
        $self->{diff_text} = $text;

        $app->add_bottom_tab('Git Diff', $dframe);
    }

    $self->refresh();
    return $self;
}

sub is_repo       { defined $_[0]{repo_root} ? 1 : 0 }
sub repo_root     { $_[0]{repo_root} }
sub branch        { $_[0]{branch} }
sub changed_files { $_[0]{changed_files} }

sub refresh {
    my ($self) = @_;
    my $app = $self->app or return;
    return if $app->headless;

    my $dir = $app->workspace // '.';
    return unless defined $dir && -d $dir;

    $self->_run_git_async(
        [ 'rev-parse', '--show-toplevel', '--abbrev-ref', 'HEAD' ],
        $dir,
        sub {
            my ($rc, $out) = @_;
            if ($rc != 0 || !defined $out || $out !~ /\S/) {
                $self->{repo_root}     = undef;
                $self->{branch}        = undef;
                $self->{changed_files} = [];
                $self->{branch_text}   = 'No Git Repo';
                $self->_update_tree();
                $app->set_status_field('git', '-');
                return;
            }
            my @lines = split /\r?\n/, $out;
            $self->{repo_root}   = $lines[0];
            $self->{branch}      = $lines[1] // 'HEAD';
            $self->{branch_text} = 'Branch: ' . $self->{branch};
            $app->set_status_field('git', 'git:' . $self->{branch});

            $self->_refresh_status();
            if (my $doc = $app->active_doc) {
                $self->_refresh_doc_gutter($doc);
            }
        },
    );
}

sub _refresh_status {
    my ($self) = @_;
    my $root = $self->{repo_root} or return;

    $self->_run_git_async(
        [ 'status', '--porcelain' ],
        $root,
        sub {
            my ($rc, $out) = @_;
            return if $rc != 0;
            my @files;
            for my $line (split /\r?\n/, ($out // '')) {
                next unless length($line) >= 4;
                my $xy   = substr($line, 0, 2);
                my $path = substr($line, 3);
                $path =~ s/\A.* -> //;
                my $abs  = File::Spec->catfile($root, $path);
                push @files, { status => $xy, rel => $path, abs => $abs };
            }
            $self->{changed_files} = \@files;
            $self->_update_tree();
        },
    );
}

sub _update_tree {
    my ($self) = @_;
    my $tree = $self->{tree} or return;

    my @kids = $self->_tree_children('');
    $tree->delete(@kids) if @kids;
    $self->{node_path} = {};

    for my $f (@{ $self->{changed_files} }) {
        my $id = 'git_' . (++$self->{seq});
        my $st = $f->{status};
        $st =~ s/\s/./g;
        $tree->insert('', 'end', -id => $id, -text => "[$st] $f->{rel}");
        $self->{node_path}{$id} = $f->{abs};
    }
}

sub _on_select_file {
    my ($self) = @_;
    my $path = $self->_selected_path() or return;
    $self->show_diff_for_path($path);
}

sub _on_open_file {
    my ($self) = @_;
    my $app  = $self->app or return;
    my $path = $self->_selected_path() or return;
    $app->open_file($path) if -f $path;
}

sub _selected_path {
    my ($self) = @_;
    my $tree = $self->{tree} or return undef;
    my @sel  = $tree->selection();
    if (@sel == 1 && defined $sel[0] && $sel[0] =~ /\s/) {
        @sel = split /\s+/, $sel[0];
    }
    my $id = $sel[0] or return undef;
    return $self->{node_path}{$id};
}

sub show_diff_for_path {
    my ($self, $path) = @_;
    my $root = $self->{repo_root} or return;
    return unless defined $path && length $path;

    $self->_run_git_async(
        [ 'diff', '--no-color', '--', $path ],
        $root,
        sub {
            my ($rc, $out) = @_;
            return if $rc != 0;
            $self->_set_diff_view($out // '');
        },
    );
}

sub _set_diff_view {
    my ($self, $diff_str) = @_;
    my $text = $self->{diff_text} or return;

    $text->configure(-state => 'normal');
    $text->delete('1.0', 'end');
    for my $line (split /\n/, $diff_str) {
        my $tag;
        if ($line =~ /\A@@/) {
            $tag = 'hunk';
        }
        elsif ($line =~ /\A\+(?!\+\+)/) {
            $tag = 'add';
        }
        elsif ($line =~ /\A-(?!--)/) {
            $tag = 'del';
        }
        if (defined $tag) {
            $text->insert('end', "$line\n", $tag);
        }
        else {
            $text->insert('end', "$line\n");
        }
    }
    $text->configure(-state => 'disabled');
}

sub _refresh_doc_gutter {
    my ($self, $doc) = @_;
    my $app  = $self->app or return;
    my $root = $self->{repo_root} or return;
    return if $app->headless;
    return unless $doc && defined $doc->path && length $doc->path;

    my $path = $doc->path;
    $self->_run_git_async(
        [ 'diff', '--no-color', '-U0', '--', $path ],
        $root,
        sub {
            my ($rc, $out) = @_;
            return if $rc != 0;
            my $map = parse_unified_diff_gutter($out // '');
            $doc->set_git_gutter($map) if $doc->can('set_git_gutter');
            if ($app->active_doc && $app->active_doc == $doc) {
                $app->redraw_active();
            }
        },
    );
}

sub parse_unified_diff_gutter {
    my ($diff_text) = @_;
    my %gutter;
    return \%gutter unless defined $diff_text && length $diff_text;

    for my $line (split /\r?\n/, $diff_text) {
        if ($line =~ /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
            my $old_cnt   = defined($2) ? int($2) : 1;
            my $new_start = int($3);
            my $new_cnt   = defined($4) ? int($4) : 1;

            if ($old_cnt == 0 && $new_cnt > 0) {
                for my $i (0 .. $new_cnt - 1) {
                    my $l0 = $new_start - 1 + $i;
                    $gutter{$l0} = 'add' if $l0 >= 0;
                }
            }
            elsif ($new_cnt == 0 && $old_cnt > 0) {
                my $l0 = $new_start > 0 ? $new_start - 1 : 0;
                $gutter{$l0} = 'del';
            }
            elsif ($new_cnt > 0) {
                for my $i (0 .. $new_cnt - 1) {
                    my $l0 = $new_start - 1 + $i;
                    $gutter{$l0} = 'mod' if $l0 >= 0;
                }
            }
        }
    }
    return \%gutter;
}

sub _run_git_async {
    my ($self, $args, $cwd, $on_done) = @_;
    my $app = $self->app or return;
    return if $app->headless;

    my ($r_fh, $w_fh);
    return unless pipe($r_fh, $w_fh);

    my $pid = fork();
    if (!defined $pid) {
        close $r_fh;
        close $w_fh;
        return;
    }

    if ($pid == 0) {
        close $r_fh;
        open(STDOUT, '>&', $w_fh) or POSIX::_exit(127);
        open(STDERR, '>', '/dev/null');
        close $w_fh;
        chdir($cwd) if defined $cwd && -d $cwd;
        { exec('git', @$args); }
        POSIX::_exit(127);
    }

    close $w_fh;
    binmode($r_fh, ':raw');

    my $jid = ++$self->{job_seq};
    my $job = {
        id      => $jid,
        pid     => $pid,
        fh      => $r_fh,
        select  => IO::Select->new($r_fh),
        buf     => '',
        on_done => $on_done,
        timer   => undef,
    };
    $self->{jobs}{$jid} = $job;
    $self->_poll_job($jid);
}

sub _poll_job {
    my ($self, $jid) = @_;
    my $app = $self->app or return;
    my $job = $self->{jobs}{$jid} or return;

    $job->{timer} = $app->after(25, sub {
        $job->{timer} = undef;
        my $cur = $self->{jobs}{$jid} or return;
        my $fh  = $cur->{fh};
        my $sel = $cur->{select};
        my $eof = 0;

        if ($fh && $sel) {
            for (1 .. 16) {
                my @ready = $sel->can_read(0);
                last unless @ready;
                my $chunk = '';
                my $n = sysread($fh, $chunk, 16384);
                if (defined $n && $n > 0) {
                    $cur->{buf} .= $chunk;
                }
                else {
                    $eof = 1;
                    last;
                }
            }
        }

        my $done = waitpid($cur->{pid}, WNOHANG);
        if ($eof || $done > 0 || $done < 0) {
            my $status = $?;
            if (!$eof && $fh && $sel) {
                while ($sel->can_read(0)) {
                    my $chunk = '';
                    my $n = sysread($fh, $chunk, 16384);
                    last unless defined $n && $n > 0;
                    $cur->{buf} .= $chunk;
                }
            }
            if ($done == 0) {
                waitpid($cur->{pid}, 0);
                $status = $?;
            }
            close $fh if $fh;
            delete $self->{jobs}{$jid};
            my $rc = ($status >> 8);
            $cur->{on_done}->($rc, $cur->{buf}) if $cur->{on_done};
            return;
        }

        $self->_poll_job($jid);
    });
}

sub _tree_children {
    my ($self, $parent_id) = @_;
    my $tree = $self->{tree} or return ();
    my @raw = eval { $tree->children($parent_id) };
    if (@raw == 1 && defined $raw[0] && $raw[0] =~ /\s/) {
        @raw = split /\s+/, $raw[0];
    }
    return grep { defined $_ && length $_ } @raw;
}

sub on_doc_open   { my ($self, $doc) = @_; $self->_refresh_doc_gutter($doc); }
sub on_doc_switch { my ($self, $doc) = @_; $self->_refresh_doc_gutter($doc); }
sub on_doc_save   { my ($self, $doc) = @_; $self->_refresh_status(); $self->_refresh_doc_gutter($doc); }

sub shutdown {
    my ($self) = @_;
    my $app = $self->app;
    for my $jid (keys %{ $self->{jobs} }) {
        my $job = delete $self->{jobs}{$jid} or next;
        if ($app && defined $job->{timer}) {
            $app->after_cancel($job->{timer});
        }
        if (defined $job->{pid}) {
            kill('TERM', $job->{pid});
            waitpid($job->{pid}, WNOHANG);
        }
        close $job->{fh} if $job->{fh};
    }
}

1;
