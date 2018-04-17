package Git::PurePerl::RefSpec::WildCard;
use Moose;
use namespace::autoclean;

has 'prefix' => ( is => 'ro', isa => 'Str', required => 1 );
has 'suffix' => ( is => 'ro', isa => 'Str', required => 1 );
has 'regex' => ( is => 'ro', isa => 'RegexpRef', lazy_build => 1 );

use overload '""' => sub {
    return $_[0]->apply("*");
};

sub _build_regex {
    my $self = shift;
    my $p = $self->prefix;
    my $s = $self->suffix;
    return qr#^\Q$p\E([^/]*)\Q$s\E$#;
}

sub match {
    my ($self, $str) = @_;
    my $re = $self->regex;
    return $str =~ m#$re#;
}

sub apply {
    return $_[0]->prefix . $_[1] . $_[0]->suffix;
}

package Git::PurePerl::RefSpec;
use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

has 'plus'	    => ( is => 'ro', isa => 'Bool', required => 1 );
has 'from'	    => ( is => 'ro', isa => 'Str | Git::PurePerl::RefSpec::WildCard', required => 1 );
has 'to'	    => ( is => 'ro', isa => 'Str | Git::PurePerl::RefSpec::WildCard', required => 1 );

coerce 'Git::PurePerl::RefSpec', from 'Str', via sub { Git::PurePerl::RefSpec->fromStr($_); };

sub fromStr {
    my ($class, $str) = @_;

    $str =~ s/^\+// or die "Not supported git refspec without +";
    my ($from, $to) = ($str =~ m/^([^:]*):([^:]*)$/) or die "Git refspec must have exactly one colon: \"$str\"";

    if ($from =~ m/^([^*]*)[*]([^*]*)$/) {
	$from = Git::PurePerl::RefSpec::WildCard->new(prefix => $1, suffix => $2);
    } elsif ($from =~ m/[*]/) {
	die "Not supported git refspec 'from' part with more than one *";
    }

    if ($to =~ m/^([^*]*)[*]([^*]*)$/) {
	$to = Git::PurePerl::RefSpec::WildCard->new(prefix => $1, suffix => $2);
    } elsif ($to =~ m/[*]/) {
	die "Not supported git refspec 'to' part with more than one *";
    }

    return $class->new(from => $from, to => $to, plus => 1);
}

use overload '""' => sub {
    return "+" . $_[0]->from . ":" . $_[0]->to;
};

sub convert {
    my ($self, $str, $reverse) = (@_);

    if ($reverse) {
	my ($stem) = $self->to->match($str) or return undef;
	return $self->from->apply($stem);
    } else {
	my ($stem) = $self->from->match($str) or return undef;
	return $self->to->apply($stem);
    }
}
