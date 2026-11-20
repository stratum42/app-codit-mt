package App::Codit::MT;

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename qw(basename dirname);
use File::Spec;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed refaddr);

our $VERSION = '0.01';

my @BUILTIN_PLUGINS = qw(
    FileBrowser
    PerlSubs
    Git
    Bookmarks
    SearchReplace
    Console
    Minimap
);

my %DARK_THEME = (
    bg         => '#0f111a',
    panel_bg   => '#161926',
    surface_bg => '#1e2233',
    border     => '#2a2f45',
    fg         => '#d6deeb',
    fg_muted   => '#7e89a8',
    accent     => '#58a6ff',
    green      => '#3fb950',
    yellow     => '#d29922',
    red        => '#f85149',
);

# Fixed status-bar column specs: [ key, char_width, anchor, default_text ]
my @STATUS_SPECS = (
    [ 'cursor',   20, 'w', 'Ln 1, Col 1'        ],
    [ 'lines',    16, 'w', '0 lines'            ],
    [ 'lang',     12, 'w', 'text'               ],
    [ 'git',      22, 'w', 'git: -'             ],
    [ 'engine',   22, 'e', 'GPU (auto)'         ],
    [ 'frame_ms', 16, 'e', '0.00 ms'            ],
);

sub new {
    my ($class, %opts) = @_;

    my $engine   = lc($opts{engine}  // 'gpu');
    my $backend  = lc($opts{backend} // 'auto');
    my $headless = $opts{headless} ? 1 : 0;
    my $ws       = $opts{workspace} // getcwd();
    $ws = abs_path($ws) if defined $ws && -d $ws;

    my $self = bless {
        engine         => $engine,
        backend        => $backend,
        headless       => $headless,
        workspace      => $ws,
        auto_exit_ms   => int($opts{auto_exit_ms} || 0),
        load_plugins   => exists $opts{load_plugins} ? ($opts{load_plugins} ? 1 : 0) : 1,
        theme          => { %DARK_THEME },

        mw             => undef,
        interp         => undef,
        toolbar        => undef,
        status_bar     => undef,
        vpaned         => undef,
        hpaned         => undef,
        left_dock      => undef,
        center_frame   => undef,
        mdi_nb         => undef,
        right_dock     => undef,
        bottom_dock    => undef,

        left_tabs      => {},   # title => frame
        bottom_tabs    => {},   # title => frame
        right_widget   => undef,
        status_labels  => {},   # key => ttk::label
        status_values  => {},   # key => string
        engine_btn     => undef,

        tabs           => [],   # list of { doc, view, frame, title, id }
        tab_by_frame   => {},   # "$frame" => tab hash
        tab_by_doc     => {},   # refaddr($doc) => tab hash
        active_tab     => undef,
        untitled_seq   => 0,

        plugins        => [],   # ordered list of plugin instances
        plugin_by_name => {},   # name => plugin instance
        left_visible   => 1,
        bottom_visible => 1,
        right_visible  => 1,
        _shutting_down => 0,
    }, $class;

    for my $spec (@STATUS_SPECS) {
        $self->{status_values}{ $spec->[0] } = $spec->[3];
    }

    if (!$headless) {
        $self->_build_gui();
    }

    if ($self->{load_plugins}) {
        $self->_load_builtin_plugins();
    }

    return $self;
}

# ---------------------------------------------------------------------------
# Public Accessors
# ---------------------------------------------------------------------------

sub mw           { $_[0]{mw} }
sub interp       { $_[0]{interp} }
sub headless     { $_[0]{headless} }
sub workspace    { $_[0]{workspace} }
sub engine       { $_[0]{engine} }
sub backend      { $_[0]{backend} }
sub theme        { $_[0]{theme} }
sub left_dock    { $_[0]{left_dock} }
sub bottom_dock  { $_[0]{bottom_dock} }
sub right_dock   { $_[0]{right_dock} }
sub mdi_notebook { $_[0]{mdi_nb} }

sub active_doc {
    my ($self) = @_;
    return $self->{active_tab} ? $self->{active_tab}{doc} : undef;
}

sub active_view {
    my ($self) = @_;
    return $self->{active_tab} ? $self->{active_tab}{view} : undef;
}

sub open_documents {
    my ($self) = @_;
    return [ map { $_->{doc} } @{ $self->{tabs} } ];
}

sub plugin {
    my ($self, $name) = @_;
    return undef unless defined $name;
    return $self->{plugin_by_name}{$name};
}

sub plugins {
    my ($self) = @_;
    return [ @{ $self->{plugins} } ];
}

# ---------------------------------------------------------------------------
# Plugin Registration & Dock Helpers
# ---------------------------------------------------------------------------

sub add_left_tab {
    my ($self, $title, $frame) = @_;
    return unless defined $title && defined $frame;
    $self->{left_tabs}{$title} = $frame;
    return if $self->{headless} || !$self->{left_dock};
    $self->{left_dock}->add($frame, '-text' => " $title ");
    return $frame;
}

sub add_bottom_tab {
    my ($self, $title, $frame) = @_;
    return unless defined $title && defined $frame;
    $self->{bottom_tabs}{$title} = $frame;
    return if $self->{headless} || !$self->{bottom_dock};
    $self->{bottom_dock}->add($frame, '-text' => " $title ");
    return $frame;
}

sub select_left_tab {
    my ($self, $target) = @_;
    return if $self->{headless} || !$self->{left_dock} || !defined $target;
    my $frame = ref($target) ? $target : $self->{left_tabs}{$target};
    return unless defined $frame;
    eval { $self->{left_dock}->select($frame) };
}

sub select_bottom_tab {
    my ($self, $target) = @_;
    return if $self->{headless} || !$self->{bottom_dock} || !defined $target;
    my $frame = ref($target) ? $target : $self->{bottom_tabs}{$target};
    return unless defined $frame;
    eval { $self->{bottom_dock}->select($frame) };
}

sub set_right_panel {
    my ($self, $widget) = @_;
    $self->{right_widget} = $widget;
    return if $self->{headless} || !$self->{right_dock} || !defined $widget;
    $widget->pack('-fill' => 'both', '-expand' => 1);
    return $widget;
}

sub set_status_field {
    my ($self, $key, $text) = @_;
    return unless defined $key;
    my $val = defined($text) ? "$text" : '';
    $self->{status_values}{$key} = $val;
    return if $self->{headless};

    my $lbl = $self->{status_labels}{$key};
    return unless defined $lbl;
    my $w = $self->{_status_widths}{$key} || 16;
    if (length($val) > $w) {
        $val = substr($val, 0, $w - 1) . '~';
    }
    eval { $lbl->configure('-text' => $val) };
    return;
}

sub get_status_field {
    my ($self, $key) = @_;
    return $self->{status_values}{$key};
}

sub after {
    my ($self, $ms, $cb) = @_;
    return undef if $self->{headless} || !$self->{mw};
    return $self->{mw}->after($ms, $cb);
}

sub after_cancel {
    my ($self, $id) = @_;
    return if $self->{headless} || !$self->{mw} || !defined $id;
    eval { $self->{mw}->afterCancel($id) };
    return;
}

# ---------------------------------------------------------------------------
# GUI Construction (Dark Theme + Locked Status Bar Geometry)
# ---------------------------------------------------------------------------

sub _build_gui {
    my ($self) = @_;
    require Tcl::Tk::MT;

    my $t  = $self->{theme};
    my $mw = Tcl::Tk::MT::MainWindow->new('-title' => 'App::Codit::MT');
    $self->{mw}     = $mw;
    $self->{interp} = $mw->interp;

    $mw->configure('-background' => $t->{bg});
    $mw->geometry('1360x820');
    $mw->minsize(900, 560);
    $mw->protocol('WM_DELETE_WINDOW', sub { $self->quit() });

    $self->_configure_styles();
    $self->_build_menubar();
    $self->_build_toolbar();
    $self->_build_status_bar();
    $self->_build_mdi_panes();
    $self->_bind_shortcuts();

    # Lock toolbar and status bar heights so text updates NEVER cause window jitter
    $mw->update('idletasks');
    for my $bar ($self->{toolbar}, $self->{status_bar}) {
        next unless defined $bar;
        my $h = eval { $bar->winfo('reqheight') } || 26;
        $h = 24 if $h < 24;
        eval {
            $bar->configure('-height' => $h);
            $self->{interp}->icall('pack', 'propagate', $bar->path, 0);
        };
    }

    return;
}

sub _configure_styles {
    my ($self) = @_;
    my $i = $self->{interp};
    my $t = $self->{theme};

    eval { $i->icall('ttk::style', 'theme', 'use', 'clam') };

    eval {
        $i->icall('ttk::style', 'configure', '.',
            '-background'      => $t->{panel_bg},
            '-foreground'      => $t->{fg},
            '-fieldbackground' => $t->{bg},
            '-bordercolor'     => $t->{border},
            '-troughcolor'     => $t->{bg},
            '-selectbackground'=> $t->{accent},
            '-selectforeground'=> $t->{bg},
        );
        $i->icall('ttk::style', 'configure', 'Dark.TFrame',
            '-background' => $t->{panel_bg},
        );
        $i->icall('ttk::style', 'configure', 'Toolbar.TFrame',
            '-background' => $t->{surface_bg},
        );
        $i->icall('ttk::style', 'configure', 'Status.TFrame',
            '-background' => $t->{surface_bg},
        );
        $i->icall('ttk::style', 'configure', 'Dark.TLabel',
            '-background' => $t->{panel_bg},
            '-foreground' => $t->{fg},
        );
        $i->icall('ttk::style', 'configure', 'Status.TLabel',
            '-background' => $t->{surface_bg},
            '-foreground' => $t->{fg},
            '-font'       => 'TkFixedFont',
            '-padding'    => [ 6, 2 ],
        );
        $i->icall('ttk::style', 'configure', 'Dark.TButton',
            '-background'  => $t->{surface_bg},
            '-foreground'  => $t->{fg},
            '-borderwidth' => 1,
            '-padding'     => [ 8, 3 ],
        );
        $i->icall('ttk::style', 'map', 'Dark.TButton',
            '-background' => [ 'active', $t->{border}, 'pressed', $t->{accent} ],
            '-foreground' => [ 'pressed', $t->{bg} ],
        );
        $i->icall('ttk::style', 'configure', 'Dark.TEntry',
            '-fieldbackground' => $t->{bg},
            '-foreground'      => $t->{fg},
            '-insertcolor'     => $t->{fg},
            '-bordercolor'     => $t->{border},
        );
        $i->icall('ttk::style', 'configure', 'Dark.TNotebook',
            '-background'  => $t->{panel_bg},
            '-borderwidth' => 0,
        );
        $i->icall('ttk::style', 'configure', 'Dark.TNotebook.Tab',
            '-background' => $t->{surface_bg},
            '-foreground' => $t->{fg_muted},
            '-padding'    => [ 10, 4 ],
        );
        $i->icall('ttk::style', 'map', 'Dark.TNotebook.Tab',
            '-background' => [ 'selected', $t->{bg} ],
            '-foreground' => [ 'selected', $t->{fg} ],
        );
        $i->icall('ttk::style', 'configure', 'Dark.Treeview',
            '-background'      => $t->{bg},
            '-fieldbackground' => $t->{bg},
            '-foreground'      => $t->{fg},
            '-rowheight'       => 22,
            '-borderwidth'     => 0,
        );
        $i->icall('ttk::style', 'configure', 'Dark.Treeview.Heading',
            '-background' => $t->{surface_bg},
            '-foreground' => $t->{fg},
        );
        $i->icall('ttk::style', 'map', 'Dark.Treeview',
            '-background' => [ 'selected', $t->{surface_bg} ],
            '-foreground' => [ 'selected', $t->{accent} ],
        );
        $i->icall('ttk::style', 'configure', 'Dark.TPanedwindow',
            '-background' => $t->{border},
        );
        $i->icall('ttk::style', 'configure', 'Dark.Vertical.TScrollbar',
            '-background'  => $t->{surface_bg},
            '-troughcolor' => $t->{bg},
            '-bordercolor' => $t->{border},
            '-arrowcolor'  => $t->{fg_muted},
        );
        $i->icall('ttk::style', 'configure', 'Dark.Horizontal.TScrollbar',
            '-background'  => $t->{surface_bg},
            '-troughcolor' => $t->{bg},
            '-bordercolor' => $t->{border},
            '-arrowcolor'  => $t->{fg_muted},
        );
    };
    return;
}

sub _build_menubar {
    my ($self) = @_;
    my $mw = $self->{mw};
    my $mod = ($^O eq 'darwin') ? 'Cmd' : 'Ctrl';

    my $menubar = $mw->Menu('-tearoff' => 0);

    my $m_file = $menubar->Menu('-tearoff' => 0);
    $m_file->add('command', '-label' => 'New File',   '-accelerator' => "$mod+N", '-command' => sub { $self->new_document() });
    $m_file->add('command', '-label' => 'Open...',    '-accelerator' => "$mod+O", '-command' => sub { $self->prompt_open_file() });
    $m_file->add('command', '-label' => 'Save',       '-accelerator' => "$mod+S", '-command' => sub { $self->save_active() });
    $m_file->add('command', '-label' => 'Save As...', '-command' => sub { $self->prompt_save_as() });
    $m_file->add('separator');
    $m_file->add('command', '-label' => 'Close Tab',  '-accelerator' => "$mod+W", '-command' => sub { $self->close_active_tab() });
    $m_file->add('separator');
    $m_file->add('command', '-label' => 'Quit',       '-accelerator' => "$mod+Q", '-command' => sub { $self->quit() });
    $menubar->add('cascade', '-label' => 'File', '-menu' => $m_file);

    my $m_edit = $menubar->Menu('-tearoff' => 0);
    $m_edit->add('command', '-label' => 'Undo', '-accelerator' => "$mod+Z",       '-command' => sub { $self->undo_active() });
    $m_edit->add('command', '-label' => 'Redo', '-accelerator' => "$mod+Shift+Z", '-command' => sub { $self->redo_active() });
    $m_edit->add('separator');
    $m_edit->add('command', '-label' => 'Toggle Bookmark', '-accelerator' => "$mod+B", '-command' => sub { $self->toggle_bookmark() });
    $menubar->add('cascade', '-label' => 'Edit', '-menu' => $m_edit);

    my $m_view = $menubar->Menu('-tearoff' => 0);
    $m_view->add('command', '-label' => 'Toggle Engine (GPU / TkText)', '-command' => sub { $self->toggle_engine() });
    $m_view->add('separator');
    $m_view->add('command', '-label' => 'Toggle Left Dock',   '-command' => sub { $self->toggle_left_dock() });
    $m_view->add('command', '-label' => 'Toggle Bottom Dock', '-command' => sub { $self->toggle_bottom_dock() });
    $m_view->add('command', '-label' => 'Toggle Minimap',     '-command' => sub { $self->toggle_right_dock() });
    $menubar->add('cascade', '-label' => 'View', '-menu' => $m_view);

    my $m_search = $menubar->Menu('-tearoff' => 0);
    $m_search->add('command', '-label' => 'Find / Replace',  '-accelerator' => "$mod+F",       '-command' => sub { $self->focus_find() });
    $m_search->add('command', '-label' => 'Find in Project', '-accelerator' => "$mod+Shift+F", '-command' => sub { $self->focus_project_search() });
    $menubar->add('cascade', '-label' => 'Search', '-menu' => $m_search);

    my $m_tools = $menubar->Menu('-tearoff' => 0);
    $m_tools->add('command', '-label' => 'Run Current File', '-accelerator' => 'F5', '-command' => sub { $self->run_current_file() });
    $m_tools->add('command', '-label' => 'Refresh Git Status', '-command' => sub {
        my $g = $self->plugin('Git');
        $g->refresh() if $g && $g->can('refresh');
    });
    $menubar->add('cascade', '-label' => 'Tools', '-menu' => $m_tools);

    my $m_help = $menubar->Menu('-tearoff' => 0);
    $m_help->add('command', '-label' => 'About App::Codit::MT', '-command' => sub { $self->show_about() });
    $menubar->add('cascade', '-label' => 'Help', '-menu' => $m_help);

    $mw->configure('-menu' => $menubar);
    return;
}

sub _build_toolbar {
    my ($self) = @_;
    my $mw = $self->{mw};
    my $tb = $mw->ttkFrame('-style' => 'Toolbar.TFrame', '-padding' => [ 6, 4 ]);
    $tb->pack('-side' => 'top', '-fill' => 'x');
    $self->{toolbar} = $tb;

    my @buttons = (
        [ 'New',      6,  sub { $self->new_document() } ],
        [ 'Open',     6,  sub { $self->prompt_open_file() } ],
        [ 'Save',     6,  sub { $self->save_active() } ],
        [ 'Undo',     6,  sub { $self->undo_active() } ],
        [ 'Redo',     6,  sub { $self->redo_active() } ],
        [ 'Find',     6,  sub { $self->focus_find() } ],
        [ 'Run (F5)', 9,  sub { $self->run_current_file() } ],
    );
    for my $b (@buttons) {
        $tb->ttkButton(
            '-text'    => $b->[0],
            '-width'   => $b->[1],
            '-style'   => 'Dark.TButton',
            '-command' => $b->[2],
        )->pack('-side' => 'left', '-padx' => 2);
    }

    my $close_btn = $tb->ttkButton(
        '-text'    => 'Close Tab [x]',
        '-width'   => 13,
        '-style'   => 'Dark.TButton',
        '-command' => sub { $self->close_active_tab() },
    );
    $close_btn->pack('-side' => 'right', '-padx' => 2);

    my $eng_label = ($self->{engine} eq 'gpu') ? 'Engine: GPU' : 'Engine: TkText';
    my $eng_btn = $tb->ttkButton(
        '-text'    => $eng_label,
        '-width'   => 15,
        '-style'   => 'Dark.TButton',
        '-command' => sub { $self->toggle_engine() },
    );
    $eng_btn->pack('-side' => 'right', '-padx' => 4);
    $self->{engine_btn} = $eng_btn;

    return;
}

sub _build_status_bar {
    my ($self) = @_;
    my $mw = $self->{mw};
    my $sb = $mw->ttkFrame('-style' => 'Status.TFrame', '-padding' => [ 4, 2 ]);
    $sb->pack('-side' => 'bottom', '-fill' => 'x');
    $self->{status_bar} = $sb;

    for my $spec (@STATUS_SPECS) {
        my ($key, $width, $anchor, $default) = @$spec;
        my $side = ($anchor eq 'e') ? 'right' : 'left';
        my $lbl = $sb->ttkLabel(
            '-text'   => $default,
            '-width'  => $width,
            '-anchor' => $anchor,
            '-font'   => 'TkFixedFont',
            '-style'  => 'Status.TLabel',
        );
        $lbl->pack('-side' => $side, '-padx' => 3);
        $self->{status_labels}{$key}  = $lbl;
        $self->{_status_widths}{$key} = $width;
    }

    return;
}

sub _build_mdi_panes {
    my ($self) = @_;
    my $mw = $self->{mw};

    my $vpaned = $mw->ttkPanedwindow('-orient' => 'vertical', '-style' => 'Dark.TPanedwindow');
    $vpaned->pack('-side' => 'top', '-fill' => 'both', '-expand' => 1);
    $self->{vpaned} = $vpaned;

    my $hpaned = $vpaned->ttkPanedwindow('-orient' => 'horizontal', '-style' => 'Dark.TPanedwindow');
    $self->{hpaned} = $hpaned;

    my $left_dock = $hpaned->ttkNotebook('-style' => 'Dark.TNotebook', '-width' => 240);
    $self->{left_dock} = $left_dock;

    my $center_host = $hpaned->ttkFrame('-style' => 'Dark.TFrame');
    $self->{center_frame} = $center_host;

    my $right_dock = $center_host->ttkFrame('-style' => 'Dark.TFrame', '-width' => 124);
    $right_dock->pack('-side' => 'right', '-fill' => 'y');
    $self->{right_dock} = $right_dock;

    my $mdi_nb = $center_host->ttkNotebook('-style' => 'Dark.TNotebook');
    $mdi_nb->pack('-side' => 'left', '-fill' => 'both', '-expand' => 1);
    $self->{mdi_nb} = $mdi_nb;

    $mdi_nb->bind('<<NotebookTabChanged>>', sub { $self->_on_mdi_tab_changed() });
    $mdi_nb->bind('<Button-2>', [ sub {
        my ($w, $x, $y) = @_;
        $self->_close_tab_at_xy($x, $y);
    }, Tcl::Tk::MT::Ev('x', 'y') ]);

    $hpaned->add($left_dock,   '-weight' => 0);
    $hpaned->add($center_host, '-weight' => 1);

    my $bottom_dock = $vpaned->ttkNotebook('-style' => 'Dark.TNotebook', '-height' => 180);
    $self->{bottom_dock} = $bottom_dock;

    $vpaned->add($hpaned,      '-weight' => 4);
    $vpaned->add($bottom_dock, '-weight' => 1);

    return;
}

sub _bind_shortcuts {
    my ($self) = @_;
    my $mw = $self->{mw};
    my @mods = ($^O eq 'darwin') ? ('Command', 'Control') : ('Control');

    for my $m (@mods) {
        $mw->bind("<$m-n>", sub { $self->new_document() });
        $mw->bind("<$m-o>", sub { $self->prompt_open_file() });
        $mw->bind("<$m-s>", sub { $self->save_active() });
        $mw->bind("<$m-w>", sub { $self->close_active_tab() });
        $mw->bind("<$m-q>", sub { $self->quit() });
        $mw->bind("<$m-f>", sub { $self->focus_find() });
        $mw->bind("<$m-F>", sub { $self->focus_project_search() });
        $mw->bind("<$m-b>", sub { $self->toggle_bookmark() });
    }
    $mw->bind('<F5>', sub { $self->run_current_file() });
    return;
}

# ---------------------------------------------------------------------------
# Plugin Loader & Event Dispatch
# ---------------------------------------------------------------------------

sub _load_builtin_plugins {
    my ($self) = @_;
    for my $name (@BUILTIN_PLUGINS) {
        my $pkg = "App::Codit::MT::Plugins::$name";
        my $ok = eval "require $pkg; 1";
        if (!$ok) {
            warn "App::Codit::MT: failed to load plugin $pkg: $@\n";
            next;
        }
        my $inst = eval { $pkg->new() };
        if (!$inst) {
            warn "App::Codit::MT: failed to construct $pkg: $@\n";
            next;
        }
        eval { $inst->init($self) };
        if ($@) {
            warn "App::Codit::MT: failed to init $pkg: $@\n";
            next;
        }
        push @{ $self->{plugins} }, $inst;
        $self->{plugin_by_name}{$name} = $inst;
        my $pname = eval { $inst->name } // $name;
        $self->{plugin_by_name}{$pname} = $inst;
    }
    return;
}

sub _emit_plugin {
    my ($self, $hook, @args) = @_;
    for my $p (@{ $self->{plugins} }) {
        next unless blessed($p) && $p->can($hook);
        eval { $p->$hook(@args) };
        warn "App::Codit::MT: plugin @{[ $p->name ]}->$hook error: $@\n" if $@;
    }
    return;
}

# ---------------------------------------------------------------------------
# Document & MDI Tab Management
# ---------------------------------------------------------------------------

sub open_file {
    my ($self, $path, %opts) = @_;
    return undef unless defined $path && length $path;

    my $abs = (-e $path) ? abs_path($path) : File::Spec->rel2abs($path);

    # Reuse existing open tab if already open
    for my $tab (@{ $self->{tabs} }) {
        my $dp = $tab->{doc}->path;
        if (defined $dp && $dp eq $abs) {
            $self->switch_to_doc($tab->{doc});
            if (defined $opts{line}) {
                $self->goto_line($opts{line}, $opts{col} // 0);
            }
            return $tab->{doc};
        }
    }

    require App::Codit::MT::Document;
    my $doc = (-f $abs)
        ? App::Codit::MT::Document->open_file($abs)
        : App::Codit::MT::Document->new_empty(basename($abs), undef, path => $abs);

    $self->_add_document_tab($doc);

    if (defined $opts{line}) {
        $self->goto_line($opts{line}, $opts{col} // 0);
    }
    return $doc;
}

sub new_document {
    my ($self, $name, $lang) = @_;
    require App::Codit::MT::Document;
    $name //= 'untitled-' . (++$self->{untitled_seq}) . '.pl';
    $lang //= 'perl';
    my $doc = App::Codit::MT::Document->new_empty($name, $lang);
    $self->_add_document_tab($doc);
    return $doc;
}

sub _add_document_tab {
    my ($self, $doc) = @_;
    require App::Codit::MT::CodeView;

    my $tab_frame;
    if (!$self->{headless} && $self->{mdi_nb}) {
        $tab_frame = $self->{mdi_nb}->ttkFrame('-style' => 'Dark.TFrame');
    }

    my $view = App::Codit::MT::CodeView->new(
        parent    => $tab_frame,
        doc       => $doc,
        engine    => $self->{engine},
        backend   => $self->{backend},
        headless  => $self->{headless},
        on_scroll => sub {
            my ($top_line, $vis_lines) = @_;
            $self->_on_view_scroll($doc, $top_line, $vis_lines);
        },
    );

    my $tab = {
        doc   => $doc,
        view  => $view,
        frame => $tab_frame,
    };

    $self->_wire_doc_callbacks($doc, $tab);

    push @{ $self->{tabs} }, $tab;
    $self->{tab_by_doc}{ refaddr($doc) } = $tab;

    if (defined $tab_frame && $self->{mdi_nb}) {
        $self->{tab_by_frame}{ $tab_frame->path } = $tab;
        $self->{mdi_nb}->add($tab_frame, '-text' => $self->_format_tab_title($doc));
        $self->{mdi_nb}->select($tab_frame);
    }

    $self->{active_tab} = $tab;
    $self->_refresh_status_for_tab($tab);
    $self->_emit_plugin('on_doc_open', $doc);
    $self->_emit_plugin('on_doc_switch', $doc);

    if (defined $view && $view->can('render_frame')) {
        eval { $view->render_frame() };
        $self->_update_frame_ms($view);
    }

    return $tab;
}

sub _wire_doc_callbacks {
    my ($self, $doc, $tab) = @_;
    $tab->{listeners} = {};

    if ($doc->can('on_change')) {
        $tab->{listeners}{change} = $doc->on_change(sub {
            $self->_update_tab_title($tab);
            if ($self->{active_tab} && $self->{active_tab} == $tab) {
                $self->_refresh_status_for_tab($tab);
            }
            $self->_emit_plugin('on_doc_change', $doc);
        });
    }
    if ($doc->can('on_cursor')) {
        $tab->{listeners}{cursor} = $doc->on_cursor(sub {
            my ($line, $col) = @_;
            if ($self->{active_tab} && $self->{active_tab} == $tab) {
                $self->set_status_field('cursor', sprintf('Ln %d, Col %d', ($line || 0) + 1, ($col || 0) + 1));
            }
            $self->_emit_plugin('on_cursor', $doc, $line, $col);
        });
    }
    if ($doc->can('on_save')) {
        $tab->{listeners}{save} = $doc->on_save(sub {
            $self->_update_tab_title($tab);
            $self->_emit_plugin('on_doc_save', $doc);
        });
    }
    return;
}

sub _format_tab_title {
    my ($self, $doc) = @_;
    my $title = ($doc->can('title') ? $doc->title : undef)
        // (defined($doc->path) ? basename($doc->path) : 'untitled');
    my $dirty = ($doc->can('dirty') && $doc->dirty) ? ' *' : '';
    return " $title$dirty ";
}

sub _update_tab_title {
    my ($self, $tab) = @_;
    return if $self->{headless} || !$self->{mdi_nb} || !$tab || !$tab->{frame};
    eval {
        $self->{mdi_nb}->tab($tab->{frame}, '-text' => $self->_format_tab_title($tab->{doc}));
    };
    return;
}

sub switch_to_doc {
    my ($self, $doc) = @_;
    return unless defined $doc;
    my $tab = $self->{tab_by_doc}{ refaddr($doc) };
    return unless defined $tab;

    $self->{active_tab} = $tab;
    if (!$self->{headless} && $self->{mdi_nb} && $tab->{frame}) {
        eval { $self->{mdi_nb}->select($tab->{frame}) };
    }
    $self->_refresh_status_for_tab($tab);
    $self->_emit_plugin('on_doc_switch', $doc);
    $self->redraw_active();
    return $doc;
}

sub _on_mdi_tab_changed {
    my ($self) = @_;
    return if $self->{headless} || !$self->{mdi_nb};
    my $sel = eval { $self->{mdi_nb}->select() };
    return unless defined $sel && length $sel;
    my $tab = $self->{tab_by_frame}{$sel};
    return unless defined $tab;
    return if $self->{active_tab} && $self->{active_tab} == $tab;

    $self->{active_tab} = $tab;
    $self->_refresh_status_for_tab($tab);
    $self->_emit_plugin('on_doc_switch', $tab->{doc});
    $self->redraw_active();
    return;
}

sub close_active_tab {
    my ($self) = @_;
    return unless $self->{active_tab};
    return $self->_close_tab($self->{active_tab});
}

sub _close_tab_at_xy {
    my ($self, $x, $y) = @_;
    return if $self->{headless} || !$self->{mdi_nb};
    my $idx = eval { $self->{mdi_nb}->index("\@$x,$y") };
    return unless defined $idx && $idx =~ /\A\d+\z/;
    my $tab = $self->{tabs}[$idx];
    $self->_close_tab($tab) if defined $tab;
    return;
}

sub _close_tab {
    my ($self, $tab) = @_;
    return unless defined $tab;
    my $doc = $tab->{doc};

    $self->_emit_plugin('on_doc_close', $doc);

    if (my $ls = $tab->{listeners}) {
        $doc->off_change($ls->{change}) if defined $ls->{change} && $doc->can('off_change');
        $doc->off_cursor($ls->{cursor}) if defined $ls->{cursor} && $doc->can('off_cursor');
        $doc->off_save($ls->{save})     if defined $ls->{save}   && $doc->can('off_save');
    }

    if ($tab->{view} && $tab->{view}->can('destroy')) {
        eval { $tab->{view}->destroy() };
    }
    if (!$self->{headless} && $self->{mdi_nb} && $tab->{frame}) {
        eval { $self->{mdi_nb}->forget($tab->{frame}) };
        eval { $tab->{frame}->destroy() };
        delete $self->{tab_by_frame}{ $tab->{frame}->path };
    }
    delete $self->{tab_by_doc}{ refaddr($doc) };
    @{ $self->{tabs} } = grep { $_ != $tab } @{ $self->{tabs} };

    if (@{ $self->{tabs} }) {
        $self->{active_tab} = $self->{tabs}[-1];
        if (!$self->{headless} && $self->{mdi_nb} && $self->{active_tab}{frame}) {
            eval { $self->{mdi_nb}->select($self->{active_tab}{frame}) };
        }
        $self->_refresh_status_for_tab($self->{active_tab});
        $self->_emit_plugin('on_doc_switch', $self->{active_tab}{doc});
    }
    else {
        $self->{active_tab} = undef;
        $self->_emit_plugin('on_doc_switch', undef);
    }
    return 1;
}

# ---------------------------------------------------------------------------
# Editor Actions & Engine Switching
# ---------------------------------------------------------------------------

sub goto_line {
    my ($self, $line, $col) = @_;
    my $tab = $self->{active_tab} or return;
    $line = 0 if !defined($line) || $line < 0;
    $col  = 0 if !defined($col)  || $col < 0;

    $tab->{doc}->goto_line($line, $col) if $tab->{doc}->can('goto_line');
    if ($tab->{view}) {
        if ($tab->{view}->can('scroll_to_line')) {
            my $vis = ($tab->{view}->can('visible_lines') ? $tab->{view}->visible_lines : 30) || 30;
            my $target_top = $line - int($vis / 3);
            $target_top = 0 if $target_top < 0;
            $tab->{view}->scroll_to_line($target_top);
        }
        $tab->{view}->render_frame() if $tab->{view}->can('render_frame');
        $self->_update_frame_ms($tab->{view});
    }
    $self->_refresh_status_for_tab($tab);
    return;
}

sub redraw_active {
    my ($self) = @_;
    my $tab = $self->{active_tab} or return;
    return unless $tab->{view} && $tab->{view}->can('render_frame');
    eval { $tab->{view}->render_frame() };
    $self->_update_frame_ms($tab->{view});
    return;
}

sub save_active {
    my ($self) = @_;
    my $doc = $self->active_doc or return;
    if (!defined $doc->path || !length $doc->path) {
        return $self->prompt_save_as();
    }
    $doc->save();
    return 1;
}

sub prompt_open_file {
    my ($self) = @_;
    return if $self->{headless} || !$self->{interp};
    my $path = eval {
        $self->{interp}->icall_scalar('tk_getOpenFile', '-initialdir' => $self->{workspace});
    };
    return unless defined $path && length $path;
    return $self->open_file($path);
}

sub prompt_save_as {
    my ($self) = @_;
    my $doc = $self->active_doc or return;
    return if $self->{headless} || !$self->{interp};
    my $path = eval {
        $self->{interp}->icall_scalar('tk_getSaveFile', '-initialdir' => $self->{workspace});
    };
    return unless defined $path && length $path;
    $doc->save($path);
    return 1;
}

sub undo_active {
    my ($self) = @_;
    my $doc = $self->active_doc or return;
    $doc->undo() if $doc->can('undo');
    $self->redraw_active();
    return;
}

sub redo_active {
    my ($self) = @_;
    my $doc = $self->active_doc or return;
    $doc->redo() if $doc->can('redo');
    $self->redraw_active();
    return;
}

sub toggle_engine {
    my ($self) = @_;
    my $next = ($self->{engine} eq 'gpu') ? 'tktext' : 'gpu';
    return $self->set_engine($next);
}

sub set_engine {
    my ($self, $new_engine) = @_;
    $new_engine = lc($new_engine // 'gpu');
    return $self->{engine} if $new_engine eq $self->{engine};
    return $self->{engine} unless $new_engine eq 'gpu' || $new_engine eq 'tktext';

    require App::Codit::MT::CodeView;
    $self->{engine} = $new_engine;

    for my $tab (@{ $self->{tabs} }) {
        my $top = ($tab->{view} && $tab->{view}->can('top_line')) ? ($tab->{view}->top_line || 0) : 0;
        if ($tab->{view} && $tab->{view}->can('destroy')) {
            eval { $tab->{view}->destroy() };
        }
        my $doc = $tab->{doc};
        my $view = App::Codit::MT::CodeView->new(
            parent    => $tab->{frame},
            doc       => $doc,
            engine    => $self->{engine},
            backend   => $self->{backend},
            headless  => $self->{headless},
            on_scroll => sub {
                my ($top_line, $vis_lines) = @_;
                $self->_on_view_scroll($doc, $top_line, $vis_lines);
            },
        );
        $tab->{view} = $view;
        $view->scroll_to_line($top) if $view->can('scroll_to_line');
        $view->render_frame()       if $view->can('render_frame');
    }

    if (!$self->{headless} && $self->{engine_btn}) {
        my $lbl = ($new_engine eq 'gpu') ? 'Engine: GPU' : 'Engine: TkText';
        eval { $self->{engine_btn}->configure('-text' => $lbl) };
    }
    if ($self->{active_tab}) {
        $self->_refresh_status_for_tab($self->{active_tab});
    }
    return $self->{engine};
}

sub focus_find {
    my ($self) = @_;
    my $p = $self->plugin('SearchReplace');
    $self->select_bottom_tab('Search');
    $p->focus_find() if $p && $p->can('focus_find');
    return;
}

sub focus_project_search {
    my ($self) = @_;
    my $p = $self->plugin('SearchReplace');
    $self->select_bottom_tab('Search');
    $p->focus_project_search() if $p && $p->can('focus_project_search');
    return;
}

sub toggle_bookmark {
    my ($self) = @_;
    my $p = $self->plugin('Bookmarks');
    if ($p && $p->can('toggle_current')) {
        $p->toggle_current();
        return;
    }
    my $doc = $self->active_doc or return;
    if ($doc->can('toggle_bookmark')) {
        $doc->toggle_bookmark($doc->cursor_line);
        $self->redraw_active();
    }
    return;
}

sub run_current_file {
    my ($self) = @_;
    my $p = $self->plugin('Console');
    $self->select_bottom_tab('Console');
    $p->run_current_file() if $p && $p->can('run_current_file');
    return;
}

sub toggle_left_dock {
    my ($self) = @_;
    return if $self->{headless} || !$self->{hpaned} || !$self->{left_dock};
    if ($self->{left_visible}) {
        eval { $self->{hpaned}->forget($self->{left_dock}) };
        $self->{left_visible} = 0;
    }
    else {
        eval { $self->{hpaned}->insert(0, $self->{left_dock}, '-weight' => 0) };
        $self->{left_visible} = 1;
    }
    return;
}

sub toggle_bottom_dock {
    my ($self) = @_;
    return if $self->{headless} || !$self->{vpaned} || !$self->{bottom_dock};
    if ($self->{bottom_visible}) {
        eval { $self->{vpaned}->forget($self->{bottom_dock}) };
        $self->{bottom_visible} = 0;
    }
    else {
        eval { $self->{vpaned}->add($self->{bottom_dock}, '-weight' => 1) };
        $self->{bottom_visible} = 1;
    }
    return;
}

sub toggle_right_dock {
    my ($self) = @_;
    return if $self->{headless} || !$self->{right_dock};
    if ($self->{right_visible}) {
        eval { $self->{right_dock}->packForget() };
        $self->{right_visible} = 0;
    }
    else {
        eval { $self->{right_dock}->pack('-side' => 'right', '-fill' => 'y') };
        $self->{right_visible} = 1;
    }
    return;
}

sub show_about {
    my ($self) = @_;
    return if $self->{headless} || !$self->{interp};
    eval {
        $self->{interp}->icall('tk_messageBox',
            '-title'   => 'About App::Codit::MT',
            '-type'    => 'ok',
            '-icon'    => 'info',
            '-message' => "App::Codit::MT $VERSION\n\nGPU-accelerated Perl IDE built on Tcl::Tk::MT and C11 XS.\nInspired by Hans Jeuken's App::Codit.",
        );
    };
    return;
}

# ---------------------------------------------------------------------------
# Status Bar Updates & Scroll Notifications
# ---------------------------------------------------------------------------

sub _on_view_scroll {
    my ($self, $doc, $top_line, $vis_lines) = @_;
    if ($self->{active_tab} && $self->{active_tab}{doc} == $doc) {
        $self->_update_frame_ms($self->{active_tab}{view});
    }
    $self->_emit_plugin('on_scroll', $doc, $top_line, $vis_lines);
    return;
}

sub _refresh_status_for_tab {
    my ($self, $tab) = @_;
    return unless defined $tab;
    my $doc  = $tab->{doc};
    my $view = $tab->{view};

    my $line = ($doc->can('cursor_line') ? $doc->cursor_line : 0) || 0;
    my $col  = ($doc->can('cursor_col')  ? $doc->cursor_col  : 0) || 0;
    my $lcnt = ($doc->can('line_count')  ? $doc->line_count  : 0) || 0;
    my $lang = ($doc->can('language')    ? $doc->language    : 'text') // 'text';

    $self->set_status_field('cursor', sprintf('Ln %d, Col %d', $line + 1, $col + 1));
    $self->set_status_field('lines',  sprintf('%d lines', $lcnt));
    $self->set_status_field('lang',   $lang);

    my $bname = ($view && $view->can('backend_name')) ? ($view->backend_name // $self->{backend}) : $self->{backend};
    my $etag  = ($self->{engine} eq 'gpu') ? "GPU ($bname)" : 'TkText';
    $self->set_status_field('engine', $etag);

    $self->_update_frame_ms($view) if defined $view;
    return;
}

sub _update_frame_ms {
    my ($self, $view) = @_;
    return unless defined $view && $view->can('last_render_ms');
    my $ms = $view->last_render_ms // 0;
    $self->set_status_field('frame_ms', sprintf('%.2f ms', $ms));
    return;
}

# ---------------------------------------------------------------------------
# Headless Benchmark Runner & MainLoop
# ---------------------------------------------------------------------------

sub run_headless_bench {
    my ($self, %opts) = @_;
    my $frames = int($opts{frames} || 120);
    $frames = 1 if $frames < 1;

    my $t0 = time();
    my $doc;
    if (defined $opts{file} && length $opts{file}) {
        $doc = $self->open_file($opts{file});
    }
    else {
        $doc = $self->active_doc || $self->new_document();
    }
    my $open_ms = (time() - $t0) * 1000.0;

    my $view  = $self->active_view;
    my $lines = $doc->line_count || 1;
    my $step  = int($lines / ($frames + 1));
    $step = 1 if $step < 1;

    my @frame_ms;
    my $bt0 = time();
    for my $f (0 .. $frames - 1) {
        my $target = ($f * $step) % $lines;
        my $ft0 = time();
        if ($view) {
            $view->scroll_to_line($target) if $view->can('scroll_to_line');
            $view->render_frame()          if $view->can('render_frame');
        }
        push @frame_ms, (time() - $ft0) * 1000.0;
    }
    my $total_s = time() - $bt0;
    $total_s = 1e-6 if $total_s <= 0;

    my @sorted = sort { $a <=> $b } @frame_ms;
    my $p50 = $sorted[ int(@sorted * 0.50) ] // 0;
    my $p95 = $sorted[ int(@sorted * 0.95) ] // $sorted[-1] // 0;
    my $bname = ($view && $view->can('backend_name')) ? ($view->backend_name // $self->{backend}) : $self->{backend};

    return {
        engine   => $self->{engine},
        backend  => $bname,
        lines    => $lines,
        open_ms  => sprintf('%.3f', $open_ms) + 0,
        frames   => $frames,
        fps      => sprintf('%.1f', $frames / $total_s) + 0,
        p50_ms   => sprintf('%.3f', $p50) + 0,
        p95_ms   => sprintf('%.3f', $p95) + 0,
    };
}

sub run {
    my ($self) = @_;
    return if $self->{headless} || !$self->{mw};

    if ($self->{auto_exit_ms} && $self->{auto_exit_ms} > 0) {
        $self->{mw}->after($self->{auto_exit_ms}, sub { $self->quit() });
    }
    $self->{mw}->MainLoop();
    $self->shutdown();
    return;
}

sub quit {
    my ($self) = @_;
    $self->shutdown();
    if (!$self->{headless} && $self->{mw}) {
        eval { $self->{mw}->destroy() };
        $self->{mw} = undef;
    }
    return;
}

sub shutdown {
    my ($self) = @_;
    return if $self->{_shutting_down};
    $self->{_shutting_down} = 1;
    $self->_emit_plugin('shutdown');
    for my $tab (@{ $self->{tabs} }) {
        if ($tab->{view} && $tab->{view}->can('destroy')) {
            eval { $tab->{view}->destroy() };
        }
    }
    return;
}

1;

__END__

=head1 NAME

App::Codit::MT - GPU-accelerated, multi-threaded Perl MDI IDE shell

=head1 SYNOPSIS

    use App::Codit::MT;

    my $app = App::Codit::MT->new(
        engine    => 'gpu',
        backend   => 'auto',
        workspace => '.',
    );
    $app->open_file('lib/App/Codit/MT.pm');
    $app->run();

=head1 DESCRIPTION

C<App::Codit::MT> provides the dark-themed MDI IDE shell, menu bar, toolbar,
dockable left/bottom/right panels, locked-geometry C<TkFixedFont> status bar,
plugin host, and live C<CodeView::GPU> / C<CodeView::TkText> viewport switcher.

=head1 CREDITS

Inspired by Hans Jeuken's L<App::Codit> and L<Tk::CodeText>. Built on
L<Tcl::Tk::MT>, with thanks to the L<Tcl::Tk>, Tcl/Tk, and Perl 5 communities.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself (the Artistic License or the GNU General Public
License).

=cut
