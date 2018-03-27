package Git::PurePerl::Remote;
use Moose;

has 'name'      => ( is => 'ro', isa => 'Str', required => 1 );
has 'push_url'  => ( is => 'ro', isa => 'Str', required => 1 );
has 'fetch_url' => ( is => 'ro', isa => 'Str', required => 1 );
has 'url'	=> ( is => 'ro', isa => 'Str', required => 0 );
has 'git'	=> ( is => 'ro', isa => 'Git::PurePerl', required => 1, weak_ref => 1 );

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

__PACKAGE__->meta->make_immutable;

1;
