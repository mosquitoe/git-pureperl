package Git::PurePerl::Protocol;
use Moose;
use MooseX::StrictConstructor;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

use Git::PurePerl::Protocol::Git;
use Git::PurePerl::Protocol::SSH;
use Git::PurePerl::Protocol::File;

has 'remote' => ( is => 'ro', isa => 'Str', required => 1 );
has 'git' => ( is => 'ro', isa => 'Git::PurePerl', required => 1, weak_ref => 1 );
has 'read_socket' => ( is => 'rw', required => 0 );
has 'write_socket' => ( is => 'rw', required => 0 );

sub connect {
    my $self = shift;

    if ($self->remote =~ m{^git://(.*?@)?(.*?)(/.*)}) {
        Git::PurePerl::Protocol::Git->meta->rebless_instance(
            $self,
            hostname => $2,
            project => $3,
        );
    } elsif ($self->remote =~ m{^file://(/.*)}) {
        Git::PurePerl::Protocol::File->meta->rebless_instance(
            $self,
            path => $1,
        );
    } elsif ($self->remote =~ m{^ssh://(?:(.*?)@)?(.*?)(/.*)}
                 or $self->remote =~ m{^(?:(.*?)@)?(.*?):(.*)}) {
        Git::PurePerl::Protocol::SSH->meta->rebless_instance(
            $self,
            $1 ? (username => $1) : (),
            hostname => $2,
            path => $3,
        );
    }

    $self->connect_socket;

    my %sha1s;
    while ( my $line = $self->read_line() ) {

        # warn "S $line";
        my ( $sha1, $name ) = $line =~ /^([a-z0-9]+) ([^\0\n]+)/;

        #use YAML; warn Dump $line;
        $sha1s{$name} = $sha1;
    }
    return \%sha1s;
}

sub fetch_pack {
    my ( $self, @sha1s ) = @_;
    return unless @sha1s;

    # Send all the wanted refs at once
    $self->send_line("want $sha1s[0] multi_ack_detailed side-band-64k\n");
    foreach my $sha1 (@sha1s) {
	next if $self->git->get_object($sha1);
	$self->send_line("want $sha1\n");
    }
    $self->send_line('');

    # Negotiate on what to transfer
    # First of all, we have the refs
    my %sha1s;
    foreach my $ref ($self->git->refs) {
	if ($ref->kind eq "commit") {
	    $sha1s{$ref->sha1} = 1;
	} elsif ($ref->kind eq "tag") {
	    $ref = $self->git->get_object($ref->object);
	    redo;
	}
    }
    my %sha1s_seen;
    my $packhash;
    HAVELOOP: while (keys %sha1s) {
	# There is still something we have
	foreach my $sha1 (keys %sha1s) {
	    $self->send_line("have $sha1\n");
	}
	$self->send_line('');

	# Check what server has
	while ( my $line = $self->read_line() ) {
	    if ( $line =~ s/^\x02// ) {
		print $line;
	    } elsif ( $line =~ /^NAK\n/ ) {
		# No more ACK's, let's try parents of the remaining commits.
		foreach my $sha1 (keys %sha1s) {
		    foreach my $parent (@{$self->git->get_object($sha1)->parent_sha1s}) {
			next if $sha1s_seen{$parent};
			$sha1s{$parent}++;
		    }
		    delete $sha1s{$sha1};
		    $sha1s_seen{$sha1}++;
		}
		next HAVELOOP;
	    } elsif ( $line =~ /^ACK ([0-9a-f]{40}) (common|ready)\n/ ) {
		# This commit is common.
		my @okq = ( $1 );
		while ( @okq ) {
		    my $sha1 = shift @okq;
		    next if exists $sha1s_seen{$sha1};
		    delete $sha1s{$sha1} if exists $sha1s{$sha1};
		    $sha1s_seen{$sha1}++;
		    push @okq, @{$self->git->get_object($sha1)->parent_sha1s};
		}
	    } else {
		die "Got strange line: $line";
	    }
	}
    }

    $self->send_line('done');

    my $pack;

    while ( my $line = $self->read_line() ) {
	if ( $line =~ s/^\x02// ) {
	    print $line;
        } elsif ( $line =~ s/^\x01// ) {
            $pack .= $line;
	} elsif ( $line =~ /^ACK ([0-9a-f]{40})\n/ ) {
	    $packhash = $1;
        } else {
            die "Unknown line: $line";
        }

        #say "s $line";
    }

    $self->git->add_pack($packhash, $pack);
    return $packhash;
}

sub send_line {
    my ( $self, $line ) = @_;
    my $length = length($line);
    if ( $length == 0 ) {
    } else {
        $length += 4;
    }

    #warn "length $length";
    my $prefix = sprintf( "%04X", $length );
    my $text = $prefix . $line;

    # warn "$text";
    $self->write_socket->print($text) || die $!;
}

sub read {
    my $self = shift;
    my $len = shift;

    my $ret = "";
    use bytes;
    while (1) {
        my $got = $self->read_socket->read( my $data, $len - length($ret));
        if (not defined $got) {
            die "error: $!";
        } elsif ( $got == 0) {
            die "EOF"
        }
        $ret .= $data;
        if (length($ret) == $len) {
            return $ret;
        }
    }
}

sub read_line {
    my $self   = shift;
    my $socket = $self->read_socket;

    my $prefix = $self->read( 4 );

    return if $prefix eq '0000';

    # warn "read prefix [$prefix]";

    my $len = 0;
    foreach my $n ( 0 .. 3 ) {
        my $c = substr( $prefix, $n, 1 );
        $len <<= 4;

        if ( $c ge '0' && $c le '9' ) {
            $len += ord($c) - ord('0');
        } elsif ( $c ge 'a' && $c le 'f' ) {
            $len += ord($c) - ord('a') + 10;
        } elsif ( $c ge 'A' && $c le 'F' ) {
            $len += ord($c) - ord('A') + 10;
        }
    }

    return $self->read( $len - 4 );
}

__PACKAGE__->meta->make_immutable;
