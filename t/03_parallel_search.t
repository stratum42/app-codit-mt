use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use App::Codit::MT::Core qw(search_dir);

my $root = tempdir(CLEANUP => 1);
make_path(
    "$root/lib",
    "$root/src",
    "$root/.git",
    "$root/blib",
    "$root/node_modules/pkg",
);

sub write_txt {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

# Searchable files
write_txt("$root/lib/alpha.pm", "package Alpha;\nsub FindMe { return 'findme'; }\n");
write_txt("$root/lib/beta.pm",  "package Beta;\n# FINDME in comment\nmy \$x = FindMe();\n");
for my $i (1 .. 16) {
    write_txt(sprintf("$root/src/mod_%02d.c", $i),
              "/* mod $i */\nint FindMe_$i(void) { return $i; }\n");
}

# Excluded directories and binary file (must NOT appear in results)
write_txt("$root/.git/HEAD", "FindMe inside git\n");
write_txt("$root/blib/out.pm", "FindMe inside blib\n");
write_txt("$root/node_modules/pkg/index.js", "FindMe inside node_modules\n");
write_txt("$root/src/binary.bin", "FindMe\x00binary_payload\n");

# 1. Multi-threaded case-sensitive search
my $mt_res;
{
    local $ENV{PERL_FORCE_SCALAR} = 0;
    $mt_res = search_dir($root, 'FindMe', 0, 5000);
}

# Expected: alpha.pm (1), beta.pm (1), mod_01..mod_16 (16) => 18 matches
is(scalar(@$mt_res), 18, 'multi-threaded case-sensitive search finds exact 18 matches');

# Verify skipped directories and binary files are absent
for my $m (@$mt_res) {
    unlike($m->{path}, qr{(?:/\.git/|/blib/|/node_modules/|binary\.bin)},
           "excluded path not returned: $m->{path}");
}

# Verify deterministic lexicographic sorting by (path, line, col)
is($mt_res->[0]{path}, "$root/lib/alpha.pm", 'first result is lib/alpha.pm');
is($mt_res->[0]{line}, 2, '1-based line number == 2');
is($mt_res->[0]{col},  4, '0-based column == 4');
like($mt_res->[0]{preview}, qr/sub FindMe/, 'preview contains matched line');

# 2. PERL_FORCE_SCALAR=1 exact bit-identical parity
my $sc_res;
{
    local $ENV{PERL_FORCE_SCALAR} = 1;
    $sc_res = search_dir($root, 'FindMe', 0, 5000);
}
is_deeply($mt_res, $sc_res, 'search_dir multi-threaded vs PERL_FORCE_SCALAR=1 is 100% identical');

# 3. Case-insensitive search
my $mt_icase;
my $sc_icase;
{
    local $ENV{PERL_FORCE_SCALAR} = 0;
    $mt_icase = search_dir($root, 'findme', 1, 5000);
}
{
    local $ENV{PERL_FORCE_SCALAR} = 1;
    $sc_icase = search_dir($root, 'findme', 1, 5000);
}
# Expected: alpha.pm (2), beta.pm (2), mod_01..mod_16 (16) => 20 matches
is(scalar(@$mt_icase), 20, 'case-insensitive search finds exact 20 matches');
is_deeply($mt_icase, $sc_icase, 'case-insensitive multi-threaded vs scalar is 100% identical');

done_testing();
