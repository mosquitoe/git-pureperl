package Git::PurePerl;
use Moose;
use MooseX::StrictConstructor;
use MooseX::Types::Path::Class;
use Compress::Zlib qw(uncompress);
use Data::Stream::Bulk;
use Data::Stream::Bulk::Array;
use Data::Stream::Bulk::Path::Class;
use DateTime;
use Digest::SHA;
use File::Find::Rule;
use Git::PurePerl::Actor;
use Git::PurePerl::Config;
use Git::PurePerl::DirectoryEntry;
use Git::PurePerl::Loose;
use Git::PurePerl::Object;
use Git::PurePerl::NewDirectoryEntry;
use Git::PurePerl::NewObject;
use Git::PurePerl::NewObject::Blob;
use Git::PurePerl::NewObject::Commit;
use Git::PurePerl::NewObject::Tag;
use Git::PurePerl::NewObject::Tree;
use Git::PurePerl::Object::Tree;
use Git::PurePerl::Object::Blob;
use Git::PurePerl::Object::Commit;
use Git::PurePerl::Object::Tag;
use Git::PurePerl::Object::Tree;
use Git::PurePerl::Pack;
use Git::PurePerl::Pack::WithIndex;
use Git::PurePerl::Pack::WithoutIndex;
use Git::PurePerl::PackIndex;
use Git::PurePerl::PackIndex::Version1;
use Git::PurePerl::PackIndex::Version2;
use Git::PurePerl::Protocol;
use Git::PurePerl::Remote;
use IO::Digest;
use IO::Socket::INET;
use Path::Class;
use namespace::autoclean;

our $VERSION = '0.53';
$VERSION = eval $VERSION;

has 'directory' => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 0,
    coerce   => 1
);

has 'gitdir' => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1
);

has 'loose' => (
    is         => 'rw',
    isa        => 'Git::PurePerl::Loose',
    required   => 0,
    lazy_build => 1,
);

has 'packs' => (
    is         => 'rw',
    isa        => 'ArrayRef[Git::PurePerl::Pack]',
    required   => 0,
    auto_deref => 1,
    lazy_build => 1,
);

has 'remotes' => (
    is	       => 'rw',
    isa	       => 'HashRef[Git::PurePerl::Remote]',
    required   => 0,
    auto_deref => 1,
    lazy_build => 1,
);

has 'description' => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        my $self = shift;
        file( $self->gitdir, 'description' )->slurp( chomp => 1 );
    }
);

has 'config' => (
    is      => 'ro',
    isa     => 'Git::PurePerl::Config',
    lazy    => 1,
    default => sub {
        my $self = shift;
        Git::PurePerl::Config->new(git => $self);
    }
);

__PACKAGE__->meta->make_immutable;

sub BUILDARGS {
    my $class  = shift;
    my $params = $class->SUPER::BUILDARGS(@_);

    $params->{'gitdir'} ||= dir( $params->{'directory'}, '.git' );
    return $params;
}

sub BUILD {
    my $self = shift;

    unless ( -d $self->gitdir ) {
        confess $self->gitdir . ' is not a directory';
    }
    unless ( not defined $self->directory or -d $self->directory ) {
        confess $self->directory . ' is not a directory';
    }
}

sub _build_loose {
    my $self = shift;
    my $loose_dir = dir( $self->gitdir, 'objects' );
    return Git::PurePerl::Loose->new( directory => $loose_dir );
}

sub _build_packs {
    my $self = shift;
    my $pack_dir = dir( $self->gitdir, 'objects', 'pack' );
    my @packs;
    foreach my $filename ( $pack_dir->children ) {
        next unless $filename =~ /\.pack$/;
        push @packs,
            Git::PurePerl::Pack::WithIndex->new( filename => $filename );
    }
    return \@packs;
}

sub _build_remotes {
    my $self = shift;
    my $remotes_config = $self->config->get_regexp(key => 'remote\..*');
    my $sorted_config = {};

    foreach my $key (keys %$remotes_config) {
	my @key = split /\./, $key;
	confess "Config reader broken for $key" unless (shift @key) eq "remote";
	my $name = shift @key;
	my $subkey = shift @key;
	confess "Strange key in config: $key" if @key;
	$sorted_config->{$name}->{$subkey} = $remotes_config->{$key};
    }

    my $remotes = {};
    foreach my $remote_name (keys %$sorted_config) {
	$remotes->{$remote_name} = Git::PurePerl::Remote->new(
	    name => $remote_name,
	    ( exists $sorted_config->{$remote_name}->{push_url} ?
	      ( push_url => $sorted_config->{$remote_name}->{push_url} )
	      : ()),
	    url => $sorted_config->{$remote_name}->{url},
	    git => $self,
	    ( exists $sorted_config->{$remote_name}->{fetch} ?
	      ( fetch_spec => $sorted_config->{$remote_name}->{fetch} )
	      : ()),
	    ( exists $sorted_config->{$remote_name}->{push} ?
	      ( push_spec => $sorted_config->{$remote_name}->{push} )
	      : ()),
	);
    }
    return $remotes;
}

sub _ref_names_recursive {
    my ( $dir, $base, $names ) = @_;

    foreach my $file ( $dir->children ) {
        if ( -d $file ) {
            my $reldir  = $file->relative($dir);
            my $subbase = $base . $reldir . "/";
            _ref_names_recursive( $file, $subbase, $names );
        } else {
            push @$names, $base . $file->basename;
        }
    }
}

sub ref_names {
    my $self = shift;
    my @names;
    foreach my $type (qw(heads remotes tags)) {
        my $dir = dir( $self->gitdir, 'refs', $type );
        next unless -d $dir;
        my $base = "refs/$type/";
        _ref_names_recursive( $dir, $base, \@names );
    }
    my $packed_refs = file( $self->gitdir, 'packed-refs' );
    if ( -f $packed_refs ) {
        foreach my $line ( $packed_refs->slurp( chomp => 1 ) ) {
            next if $line =~ /^#/;
            next if $line =~ /^\^/;
            my ( $sha1, $name ) = split ' ', $line;
            push @names, $name;
        }
    }
    return @names;
}

sub refs_sha1 {
    my $self = shift;
    return map { $self->ref_sha1($_) } $self->ref_names;
}

sub refs {
    my $self = shift;
    return map { $self->ref($_) } $self->ref_names;
}

sub ref_sha1 {
    my ( $self, $wantref ) = @_;
    my $dir = dir( $self->gitdir, 'refs' );
    return unless -d $dir;

    if ($wantref eq "HEAD") {
        my $file = file($self->gitdir, 'HEAD');
        my $sha1 = file($file)->slurp
            || confess("Error reading $file: $!");
        chomp $sha1;
        return _ensure_sha1_is_sha1( $self, $sha1 );
    }

    foreach my $file ( File::Find::Rule->new->file->in($dir) ) {
        my $ref = 'refs/' . file($file)->relative($dir)->as_foreign('Unix');
        if ( $ref eq $wantref ) {
            my $sha1 = file($file)->slurp
                || confess("Error reading $file: $!");
            chomp $sha1;
            return _ensure_sha1_is_sha1( $self, $sha1 );
        }
    }

    my $packed_refs = file( $self->gitdir, 'packed-refs' );
    if ( -f $packed_refs ) {
        my $last_name;
        my $last_sha1;
        foreach my $line ( $packed_refs->slurp( chomp => 1 ) ) {
            next if $line =~ /^#/;
            my ( $sha1, $name ) = split ' ', $line;

            return _ensure_sha1_is_sha1( $self, $last_sha1 ) if $last_name and $last_name eq $wantref and (defined $name and $name ne $wantref or not defined $name and $sha1 =~ s/^\^//);

            $last_name = $name;
            $last_sha1 = $sha1;
        }
        return _ensure_sha1_is_sha1( $self, $last_sha1 ) if $last_name eq $wantref;
    }
    return undef;
}

sub _ensure_sha1_is_sha1 {
    my ( $self, $sha1 ) = @_;
    return $self->ref_sha1($1) if $sha1 =~ /^ref: (.*)/;
    return $sha1;
}

sub ref {
    my ( $self, $wantref ) = @_;
    return $self->get_object( $self->ref_sha1($wantref) );
}

sub master_sha1 {
    my $self = shift;
    return $self->ref_sha1('refs/heads/master');
}

sub master {
    my $self = shift;
    return $self->ref('refs/heads/master');
}

sub head_sha1 {
    my $self = shift;
    return $self->ref_sha1('HEAD');
}

sub head {
    my $self = shift;
    return $self->ref('HEAD');
}

sub get_object {
    my ( $self, $sha1 ) = @_;
    return unless $sha1;
    return $self->get_object_packed($sha1) || $self->get_object_loose($sha1);
}

sub get_objects {
    my ( $self, @sha1s ) = @_;
    return map { $self->get_object($_) } @sha1s;
}

sub get_object_packed {
    my ( $self, $sha1 ) = @_;

    foreach my $pack ( $self->packs ) {
        my ( $kind, $size, $content ) = $pack->get_object($sha1);
        if ( defined($kind) && defined($size) && defined($content) ) {
            return $self->create_object( $sha1, $kind, $size, $content );
        }
    }
}

sub get_object_loose {
    my ( $self, $sha1 ) = @_;

    my ( $kind, $size, $content ) = $self->loose->get_object($sha1);
    if ( defined($kind) && defined($size) && defined($content) ) {
        return $self->create_object( $sha1, $kind, $size, $content );
    }
}

sub create_object {
    my ( $self, $sha1, $kind, $size, $content ) = @_;
    if ( $kind eq 'commit' ) {
        return Git::PurePerl::Object::Commit->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
            git     => $self,
        );
    } elsif ( $kind eq 'tree' ) {
        return Git::PurePerl::Object::Tree->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
            git     => $self,
        );
    } elsif ( $kind eq 'blob' ) {
        return Git::PurePerl::Object::Blob->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
            git     => $self,
        );
    } elsif ( $kind eq 'tag' ) {
        return Git::PurePerl::Object::Tag->new(
            sha1    => $sha1,
            kind    => $kind,
            size    => $size,
            content => $content,
            git     => $self,
        );
    } else {
        confess "unknown kind $kind: $content";
    }
}

sub all_sha1s {
    my $self = shift;
    my $dir = dir( $self->gitdir, 'objects' );

    my @streams;
    push @streams, $self->loose->all_sha1s;

    foreach my $pack ( $self->packs ) {
        push @streams, $pack->all_sha1s;
    }

    return Data::Stream::Bulk::Cat->new( streams => \@streams );
}

sub all_objects {
    my $self   = shift;
    my $stream = $self->all_sha1s;
    return Data::Stream::Bulk::Filter->new(
        filter => sub { return [ $self->get_objects(@$_) ] },
        stream => $stream,
    );
}

sub sha1_short {
    my $self = shift;
    my $sha1 = shift;

    my $cpxl = 6; # Minimal length of hash
    my $shs = substr $sha1, 0, $cpxl;

    foreach my $hash ( $self->all_sha1s ) {
	next unless $hash =~ /^$shs/;
	$cpxl++;
	$shs = substr $sha1, 0, $cpxl;
	redo;
    }

    return $shs;
}

sub put_object {
    my ( $self, $object, $ref ) = @_;
    $self->loose->put_object($object);

    if ( $object->kind eq 'commit' ) {
        $ref = 'master' unless $ref;
        $self->update_ref( $ref, $object->sha1 );
    }
}

sub update_ref {
    my ( $self, $refname, $sha1 ) = @_;
    my @sref = split m#/#, $refname or die "Empty refname in update_ref";
    my $ref;
    if (@sref == 1) {
	$ref = file( $self->gitdir, 'refs', 'heads', $refname );
    } elsif ($sref[0] eq "refs") {
	$ref = file( $self->gitdir, @sref );
    } else {
	$ref = file( $self->gitdir, 'refs', @sref );
    }
    $ref->parent->mkpath;
    my $ref_fh = $ref->openw;
    $ref_fh->print($sha1) || die "Error writing to $ref";
}

sub ref_head {
    my ( $self, $refname ) = @_;
    $self->_write_head("ref: refs/heads/$refname");
}

sub detach_head {
    my ( $self, $sha1 ) = @_;
    $self->_write_head($sha1);
}

sub _write_head {
    my ( $self, $value ) = @_;

    my $head = file( $self->gitdir, 'HEAD' );
    my $head_fh = $head->openw;
    $head_fh->print($value)
        || die "Error writing to $head";
}


sub init {
    my ( $class, %arguments ) = @_;

    my $directory = $arguments{directory};
    my $git_dir;

    unless ( defined $directory ) {
        $git_dir = $arguments{gitdir}
            || confess
            "init() needs either a 'directory' or a 'gitdir' argument";
    } else {
        if ( not defined $arguments{gitdir} ) {
            $git_dir = $arguments{gitdir} = dir( $directory, '.git' );
        }
        dir($directory)->mkpath;
    }

    dir($git_dir)->mkpath;
    dir( $git_dir, 'refs',    'tags' )->mkpath;
    dir( $git_dir, 'objects', 'info' )->mkpath;
    dir( $git_dir, 'objects', 'pack' )->mkpath;
    dir( $git_dir, 'branches' )->mkpath;
    dir( $git_dir, 'hooks' )->mkpath;

    my $bare = defined($directory) ? 'false' : 'true';
    $class->_add_file(
        file( $git_dir, 'config' ),
        "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = $bare\n\tlogallrefupdates = true\n"
    );
    $class->_add_file( file( $git_dir, 'description' ),
        "Unnamed repository; edit this file to name it for gitweb.\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'applypatch-msg' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'post-commit' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'post-receive' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'post-update' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file(
        file( $git_dir, 'hooks', 'pre-applypatch' ),
        "# add shell script and make executable to enable\n"
    );
    $class->_add_file( file( $git_dir, 'hooks', 'pre-commit' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file( file( $git_dir, 'hooks', 'pre-rebase' ),
        "# add shell script and make executable to enable\n" );
    $class->_add_file( file( $git_dir, 'hooks', 'update' ),
        "# add shell script and make executable to enable\n" );

    dir( $git_dir, 'info' )->mkpath;
    $class->_add_file( file( $git_dir, 'info', 'exclude' ),
        "# *.[oa]\n# *~\n" );

    return $class->new(%arguments);
}

sub checkout {
    my ( $self, $directory, $tree ) = @_;
    $directory ||= $self->directory;
    $tree ||= $self->master->tree;
    confess("Missing tree") unless $tree;
    foreach my $directory_entry ( $tree->directory_entries ) {
        my $filename = file( $directory, $directory_entry->filename );
        my $sha1     = $directory_entry->sha1;
        my $mode     = $directory_entry->mode;
        my $object   = $self->get_object($sha1);
        if ( $object->kind eq 'blob' ) {
            $self->_add_file( $filename, $object->content );
            chmod( oct( '0' . $mode ), $filename )
                || die "Error chmoding $filename to $mode: $!";
        } elsif ( $object->kind eq 'tree' ) {
            dir($filename)->mkpath;
            $self->checkout( $filename, $object );
        } else {
            die $object->kind;
        }
    }
}

sub new_remote {
    my $self = shift;

    my $obj;
    if ((@_ == 1) and (CORE::ref $_[0]) eq "HASH") {
	$obj = Git::PurePerl::Remote->new({ %{$_[0]}, git => $self });
    } else {
	$obj = Git::PurePerl::Remote->new(@_, git => $self);
    }

    die "Error adding remote " . $obj->name . ": Name collision." if exists $self->remotes->{$obj->name};

    $self->config->set(
	key => "remote." . $obj->name . ".url",
	value => $obj->fetch_url,
	filename => $self->gitdir->file("config"),
    );

    $self->config->set(
	key => "remote." . $obj->name . ".push_url",
	value => $obj->push_url,
	filename => $self->gitdir->file("config"),
    ) if $obj->fetch_url ne $obj->push_url;

    $self->config->set(
	key => "remote." . $obj->name . ".fetch",
	value => $obj->fetch_spec,
	filename => $self->gitdir->file("config"),
    ) if $obj->fetch_spec;

    $self->config->set(
	key => "remote." . $obj->name . ".push",
	value => $obj->push_spec,
	filename => $self->gitdir->file("config"),
    ) if $obj->push_spec;

    $self->remotes->{$obj->name} = $obj;
    return $obj;
}

sub clone {
    my $self = shift;

    my $url;
    if (@_  == 2) {
        # For backwards compatibility
        $url = "git://$_[0]";
        $url .= "/" unless $_[1] =~ m{^/};
        $url .= $_[1];
    } else {
        $url = shift;
    }

    my $remote = $self->new_remote(name => 'origin', url => $url, fetch => "+refs/heads/*:refs/remotes/origin/*");
    my $head = $remote->fetch('HEAD');

    $self->update_ref( master => $head );
    $self->ref_head( "master" );
}

sub add_pack {
    my ( $self, $hash, $data ) = @_;

    my $filename
        = file( $self->gitdir, 'objects', 'pack', 'pack-' . $hash . '.pack' );
    $self->_add_file( $filename, $data );

    my $pack
        = Git::PurePerl::Pack::WithoutIndex->new( filename => $filename );
    $pack->create_index();
}

sub _add_file {
    my ( $class, $filename, $contents ) = @_;
    my $fh = $filename->openw || confess "Error opening to $filename: $!";
    binmode($fh); #important for Win32
    $fh->print($contents) || confess "Error writing to $filename: $!";
    $fh->close || confess "Error closing $filename: $!";
}

1;

__END__

=head1 NAME

Git::PurePerl - A Pure Perl interface to Git repositories

=head1 SYNOPSIS

    my $git = Git::PurePerl->new(
        directory => '/path/to/git/'
    );
    $git->master->committer;
    $git->master->comment;
    $git->get_object($git->master->tree);

=head1 DESCRIPTION

This module is a Pure Perl interface to Git repositories.

It was mostly based on Grit L<http://grit.rubyforge.org/>.

=head1 METHODS

=over 4

=item master

=item get_object

=item get_object_packed

=item get_object_loose

=item create_object

=item all_sha1s

=back

=head1 MAINTAINANCE

This module is maintained in git at L<http://github.com/broquaint/git-pureperl/>.

Patches are welcome, please come speak to one of the L<Gitalist> team
on C<< #gitalist >>.

=head1 AUTHOR

Leon Brocard <acme@astray.com>

=head1 CONTRIBUTORS

=over 4

=item Chris Reinhardt

=item Tomas (t0m) Doran

=item Dan (broquaint) Brook

=item Alex Vandiver

=item Dagfinn Ilmari MannsE<aring>ker

=back

=head1 COPYRIGHT

Copyright (C) 2008, Leon Brocard and the above mentioned contributors.

=head1 LICENSE

This module is free software; you can redistribute it or
modify it under the same terms as Perl itself.

=cut
