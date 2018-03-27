package Git::PurePerl::Remote;
use Moose;

has 'name'      => ( is => 'ro', isa => 'Str', required => 1 );
has 'push_url'  => ( is => 'ro', isa => 'Str', required => 1 );
has 'fetch_url' => ( is => 'ro', isa => 'Str', required => 1 );
has 'url'	=> ( is => 'ro', isa => 'Str', required => 0 );
has 'git'	=> ( is => 'ro', isa => 'Git::PurePerl', required => 1, weak_ref => 1 );
has 'protocol'  => ( is => 'rw', isa => 'Git::PurePerl::Protocol', required => 0, lazy_build => 1 );
has 'refs'	=> ( is => 'rw', isa => 'HashRef[Str]', required => 0, lazy_build => 1 );

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
    return Git::PurePerl::Protocol->new(remote => $self->fetch_url)
}

sub reconnect {
    my $self = shift;
    $self->protocol($self->_build_protocol());
}

sub _build_refs {
    my $self = shift;
    return $self->protocol->connect;
}

sub fetch {
    my $self = shift;
    my $what = shift;

    return undef unless exists $self->refs->{$what};

    my $sha1 = $self->refs->{$what};
    my $data = $self->protocol->fetch_pack($sha1);

    $self->git->add_pack($sha1, $data);
    $self->git->update_ref( $self->name . "/" . $what => $sha1 );

    return $sha1;
}

__PACKAGE__->meta->make_immutable;

1;
