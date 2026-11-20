package App::Codit::MT::Plugin;

use strict;
use warnings;
use Scalar::Util qw(weaken);

our $VERSION = '0.01';

=head1 NAME

App::Codit::MT::Plugin - Base class for App::Codit::MT IDE plugins

=head1 SYNOPSIS

    package App::Codit::MT::Plugins::Example;
    use strict;
    use warnings;
    use parent 'App::Codit::MT::Plugin';

    sub name { 'Example' }

    sub init {
        my ($self, $app) = @_;
        $self->SUPER::init($app);
        return if $app->headless;

        my $frame = $app->left_dock->ttkFrame(-style => 'Dark.TFrame');
        $app->add_left_tab('Example', $frame);
    }

    sub on_doc_switch {
        my ($self, $doc) = @_;
        ...
    }

    1;

=head1 DESCRIPTION

C<App::Codit::MT::Plugin> defines the base lifecycle interface for plugins
hosted by L<App::Codit::MT>. Subclasses inherit default no-op implementations
for all lifecycle hooks and override only the hooks they need.

=head1 METHODS

=head2 new(%args)

Constructs a plugin instance. Stores any supplied key/value pairs on the
blessed hashref.

=head2 name()

Returns the plugin's short identifier (defaults to the trailing package
component).

=head2 app()

Returns the owning L<App::Codit::MT> instance (stored as a weakened reference
by C<init>).

=head2 Lifecycle Hooks

=over 4

=item * C<init($app)> - Called once when the plugin is loaded.

=item * C<on_doc_open($doc)> - Called after a document is opened or created.

=item * C<on_doc_switch($doc)> - Called when the active MDI document changes (C<$doc> may be C<undef> if all tabs are closed).

=item * C<on_doc_save($doc)> - Called after a document is saved to disk.

=item * C<on_doc_change($doc)> - Called when a document's text buffer is modified.

=item * C<on_cursor($doc, $line, $col)> - Called when the cursor moves in C<$doc>.

=item * C<on_scroll($doc, $top_line, $vis_lines)> - Called when the viewport scrolls.

=item * C<on_doc_close($doc)> - Called when a document tab is closed.

=item * C<shutdown()> - Called when the IDE is closing to release timers or child processes.

=back

=cut

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

sub name {
    my ($self) = @_;
    my $pkg = ref($self) || $self;
    $pkg =~ s/\A.*:://;
    return $pkg;
}

sub app {
    my ($self) = @_;
    return $self->{app};
}

sub init {
    my ($self, $app) = @_;
    $self->{app} = $app;
    weaken($self->{app}) if ref($app);
    return $self;
}

sub on_doc_open   { return }
sub on_doc_switch { return }
sub on_doc_save   { return }
sub on_doc_change { return }
sub on_cursor     { return }
sub on_scroll     { return }
sub on_doc_close  { return }
sub shutdown      { return }

1;
