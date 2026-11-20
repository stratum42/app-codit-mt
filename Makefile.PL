use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my $is_darwin = ($^O eq 'darwin');
my $is_linux  = ($^O eq 'linux');
my $is_win32  = ($^O eq 'MSWin32');

my $CFG_CC    = $Config{cc} || 'cc';
my $is_msvc   = ($is_win32 && $CFG_CC =~ /(?:^|[\\\/])cl(?:\.exe)?$/i) ? 1 : 0;

my $DLEXT          = $Config{dlext}      || ($is_win32 ? 'dll' : 'so');
my $OBJ            = $Config{obj_ext}    || ($is_msvc ? '.obj' : '.o');
my $CFG_LD         = $Config{ld}         || $CFG_CC;
my $CFG_CCFLAGS    = $Config{ccflags}    // '';
my $CFG_OPTIMIZE   = $Config{optimize}   // ($is_msvc ? '/O2' : '-O2');
my $CFG_CCCDLFLAGS = $Config{cccdlflags} // ($is_linux ? '-fPIC' : '');
my $CFG_LDDLFLAGS  = $Config{lddlflags}  // ($is_darwin ? '-bundle -undefined dynamic_lookup'
                                           : ($is_msvc   ? '/DLL' : '-shared'));

# Locate xsubpp & default typemap from active @INC (supports uninstalled perl5-mt)
my ($XSUBPP_BIN, $TYPEMAP_FILE);
for my $dir (@INC) {
    next if ref $dir;
    if (!$XSUBPP_BIN && -f "$dir/ExtUtils/xsubpp") {
        $XSUBPP_BIN = "$dir/ExtUtils/xsubpp";
    }
    if (!$TYPEMAP_FILE && -f "$dir/ExtUtils/typemap") {
        $TYPEMAP_FILE = "$dir/ExtUtils/typemap";
    }
}
die "Could not locate ExtUtils/xsubpp in \@INC\n" unless $XSUBPP_BIN;
my $TYPEMAP_ARG = $TYPEMAP_FILE ? "-typemap \"$TYPEMAP_FILE\"" : '';

my @sys_libs;
if ($is_darwin) {
    push @sys_libs, '-lpthread';
} elsif ($is_linux) {
    push @sys_libs, '-lpthread', '-lm';
} elsif ($is_win32) {
    push @sys_libs, ($is_msvc ? () : ('-lm'));
} else {
    push @sys_libs, '-lpthread';
}

my $WIN32_PERL_LIB = $is_win32 ? '$(PERL_ARCHIVE)' : '';
my $CORE_LIBS = join(' ', grep { length } ($WIN32_PERL_LIB, @sys_libs));

my $CORE_BUNDLE = "blib/arch/auto/App/Codit/MT/Core/Core.$DLEXT";

my @CORE_OBJS = (
    "c/piece_table$OBJ",
    "c/syntax$OBJ",
    "c/search$OBJ",
    "c/minimap$OBJ",
);

my @exe_files = (-f 'bin/codit-mt') ? ('bin/codit-mt') : ();

WriteMakefile(
    NAME             => 'App::Codit::MT',
    VERSION_FROM     => 'lib/App/Codit/MT/Core.pm',
    ABSTRACT         => 'Multi-threaded Perl/Tk MDI editor inspired by App::Codit',
    AUTHOR           => 'stratum42',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',
    EXE_FILES        => \@exe_files,
    XS               => {},
    C                => [],
    OBJECT           => '',
    clean            => {
        FILES => join(' ',
            'Core.c', "Core$OBJ",
            @CORE_OBJS,
            $CORE_BUNDLE,
        ),
    },
);

package MY;

sub dynamic {
    my $self = shift;
    my $base = $self->SUPER::dynamic(@_);
    return $base . "\n"
         . "dynamic :: $CORE_BUNDLE\n"
         . "\t\$(NOECHO) \$(NOOP)\n";
}

sub postamble {
    my $self = shift;
    my $c11_std   = $is_msvc
        ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS'
        : '-std=c11 -Wall -Wextra';
    my $c11_xs    = $is_msvc
        ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS'
        : '-std=c11';
    my $cc_c_flag = $is_msvc ? '/c' : '-c';
    my $obj_out   = $is_msvc ? '/Fo$@' : '-o $@';
    my $ld_out    = $is_msvc ? '/OUT:$@' : '-o $@';

    my $core_objs_str = join(' ', @CORE_OBJS);

    return <<"EOF";

CODIT_INC      = -I. -Ic
CODIT_CC       = $CFG_CC
CODIT_LD       = $CFG_LD
CODIT_CCFLAGS    = $CFG_CCFLAGS
CODIT_OPTIMIZE   = $CFG_OPTIMIZE
CODIT_CCCDLFLAGS = $CFG_CCCDLFLAGS
CODIT_LDDLFLAGS  = $CFG_LDDLFLAGS
CODIT_XSUBPP     = \$(ABSPERLRUN) "$XSUBPP_BIN" $TYPEMAP_ARG
CODIT_CC_C11     = \$(CODIT_CC) $cc_c_flag \$(CODIT_INC) \$(CODIT_CCFLAGS) \$(CODIT_OPTIMIZE) \$(CODIT_CCCDLFLAGS) $c11_std
CODIT_CC_XS      = \$(CODIT_CC) $cc_c_flag \$(CODIT_INC) "-I\$(PERL_INC)" \$(CODIT_CCFLAGS) \$(CODIT_OPTIMIZE) \$(CODIT_CCCDLFLAGS) $c11_xs -DVERSION=\\"\$(VERSION)\\" -DXS_VERSION=\\"\$(XS_VERSION)\\"

Core.c : Core.xs c/mt_compat.h c/piece_table.h c/syntax.h c/search.h c/minimap.h
\t\$(CODIT_XSUBPP) Core.xs > Core.xsc && \$(MV) Core.xsc Core.c

Core$OBJ : Core.c
\t\$(CODIT_CC_XS) $obj_out Core.c

c/piece_table$OBJ : c/piece_table.c c/piece_table.h
\t\$(CODIT_CC_C11) $obj_out c/piece_table.c

c/syntax$OBJ : c/syntax.c c/syntax.h c/piece_table.h
\t\$(CODIT_CC_C11) $obj_out c/syntax.c

c/search$OBJ : c/search.c c/search.h c/piece_table.h c/tkmt_thread.h
\t\$(CODIT_CC_C11) $obj_out c/search.c

c/minimap$OBJ : c/minimap.c c/minimap.h c/piece_table.h c/syntax.h c/tkmt_thread.h
\t\$(CODIT_CC_C11) $obj_out c/minimap.c

$CORE_BUNDLE : Core$OBJ $core_objs_str
\t\$(MKPATH) blib/arch/auto/App/Codit/MT/Core
\t\$(CODIT_LD) \$(CODIT_LDDLFLAGS) Core$OBJ $core_objs_str $ld_out $CORE_LIBS
\t\$(CHMOD) 755 \$\@
EOF
}
