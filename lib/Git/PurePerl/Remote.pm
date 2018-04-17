package Git::PurePerl::Remote;
use Moose;
use Git::PurePerl::RefSpec;
use namespace::autoclean;

has 'name'      => ( is => 'ro', isa => 'Str', required => 1 );
has 'push_url'  => ( is => 'ro', isa => 'Str', required => 1 );
has 'fetch_url' => ( is => 'ro', isa => 'Str', required => 1 );
has 'url'	=> ( is => 'ro', isa => 'Str', required => 0 );
has 'push_spec'	=> ( is => 'ro', isa => 'Git::PurePerl::RefSpec', required => 0, coerce => 1 );
has 'fetch_spec' => (is => 'ro', isa => 'Git::PurePerl::RefSpec', required => 0, coerce => 1 );
has 'git'	=> ( is => 'ro', isa => 'Git::PurePerl', required => 1, weak_ref => 1 );
has 'protocol'  => ( is => 'rw', isa => 'Git::PurePerl::Protocol', required => 0, lazy_build => 1, clearer => '_clear_protocol' );
has 'refs'	=> ( is => 'rw', isa => 'HashRef[Str]', required => 0, lazy_build => 1, clearer => '_clear_refs' );

around BUILDARGS => sub {
    my $orig = shift;
    my $class = shift;

    my @args;

    if ((@_ == 1) and ref $_[0] eq "HASH") {
	if (exists $_[0]->{url}) {
	    @args = (
		push_url => $_[0]->{url},
		fetch_url => $_[0]->{url},
		%{$_[0]}
	    );
	} else {
	    @args = @_;
	}
    } else {
	if (exists { @_ }->{url}) {
	    @args = (
		push_url => { @_ }->{url},
		fetch_url => { @_ }->{url},
		@_
	    );
	} else {
	    @args = @_;
	}
    }

    return $class->$orig(@args);
};

sub _build_protocol {
    my $self = shift;
    return Git::PurePerl::Protocol->new(remote => $self->fetch_url, git => $self->git);
}

sub _build_refs {
    my $self = shift;
    return $self->protocol->connect;
}

sub reconnect {
    my $self = shift;
    $self->_clear_protocol();
    $self->_clear_refs();
}

sub fetch_all {
    my $self = shift;

    $self->reconnect();
    $self->fetch( grep { $self->fetch_spec->from->match($_); } keys %{$self->refs} );
}

sub fetch {
    my ($self, @what) = @_;

    map { return undef unless exists $self->refs->{$_} } @what;
    my $sha1 = $self->protocol->fetch_pack(map { $self->refs->{$_} } @what);
    foreach my $ref (@what) {
    }
    map { $self->git->update_ref( $self->fetch_spec->convert($_) => $self->refs->{$_} ); } @what;

    return $sha1;
}

__PACKAGE__->meta->make_immutable;

1;
