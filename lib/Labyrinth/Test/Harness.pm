package Labyrinth::Test::Harness;

use warnings;
use strict;
$|++;

our $VERSION = '1.00';

#----------------------------------------------------------------------------

=head1 NAME

Labyrinth::Test::Harness - Test Harness for Labyrinth Plugin modules

=head1 SYNOPSIS

    my $harness = Labyrinth::Test::Harness->new();
    $harness->new();

    my $res = $harness->prep('file1.sql',;file2.sql');

    $res = $harness->labyrinth(@plugins);

    $res = $harness->action('Base::Admin');

    $harness->refresh( \@plugins );
    $harness->refresh(
        \@plugins,
        { test1 => 1 },
        { test2 => 2 } );

    $harness->cleanup;

    $harness->clear();
    my $vars   = $harness->vars;
    my $params = $harness->params;
    $harness->set_params( name => 'Test', test => 1 );
    $harness->set_vars( name => 'Test', test => 1 );

    my $error = $harness->error;

    my $config    = $harness->config;
    my $directory = $harness->directory;
    $harness->copy_files($source,$target);

=head1 DESCRIPTION

Contains all the harness code around Labyrinth, to enable plugin testing.

=cut

#----------------------------------------------------------------------------
# Libraries

use base qw(Class::Accessor::Fast);

use Config::IniFiles;
use File::Basename;
use File::Copy;
use File::Path;
use IO::File;

use Module::Pluggable   search_path => ['Labyrinth::Plugin'];

# Required Core
use Labyrinth;
use Labyrinth::Audit;
use Labyrinth::DTUtils;
use Labyrinth::Globals  qw(:all);
use Labyrinth::Mailer;
use Labyrinth::Plugins;
use Labyrinth::Request;
use Labyrinth::Session;
use Labyrinth::Support;
use Labyrinth::Writer;
use Labyrinth::Variables;

#----------------------------------------------------------------------------
# Default Test Variables

my $CONFIG      = 't/_DBDIR/test-config.ini';
my $DIRECTORY   = 't/_DBDIR';

#----------------------------------------------------------------------------
# Class Methods

sub new {
    my ($class, %hash) = @_;
    my $self = {};
    bless $self, $class;

    $self->config(      $hash{config}    || $CONFIG    );
    $self->directory(   $hash{directory} || $DIRECTORY );

    return $self;
}

sub DESTROY {
    my $self = shift;
    $self->cleanup;
}

#----------------------------------------------------------------------------
# Object Methods

__PACKAGE__->mk_accessors(qw( config directory ));

sub prep {
    my ($self,@sql) = @_;
    $self->{error} = '';

    my $directory = $self->directory;

    # prep test directories
    rmtree($directory);
    mkpath($directory) or ( $self->{error} = "cannot create test directory" && return 0 );

    for my $dir ('html','cgi-bin') {
        unless ($self->copy_files("vhost/$dir","$directory/$dir")) {
            $self->{error} = "cannot create test files: " . $self->{error};
            return 0;
        }
    }

    mkpath("$directory/html/cache") or ( $self->{error} = "cannot create cache directory" && return 0 );

    # prep database
    eval "use Test::Database";
    if($@) {
        $self->{error} = "Unable to load Test::Database: $@";
        return 0;
    }

    my $td1 = Test::Database->handle( 'mysql' );
    unless($td1) {
        $self->{error} = "Unable to load  a test database instance";
        return 0;
    }

    create_mysql_databases($td1,@sql);

    my %opts;
    ($opts{dsn}, $opts{dbuser}, $opts{dbpass}) =  $td1->connection_info();
    ($opts{driver})    = $opts{dsn} =~ /dbi:([^;:]+)/;
    ($opts{database})  = $opts{dsn} =~ /database=([^;]+)/;
    ($opts{database})  = $opts{dsn} =~ /dbname=([^;]+)/     unless($opts{database});
    ($opts{dbhost})    = $opts{dsn} =~ /host=([^;]+)/;
    ($opts{dbport})    = $opts{dsn} =~ /port=([^;]+)/;
    my %db_config = map {my $v = $opts{$_}; defined($v) ? ($_ => $v) : () }
                        qw(driver database dbfile dbhost dbport dbuser dbpass);

    # prep config files
    unless( $self->create_config(\%db_config) ) {
        $self->{error} = "Failed to create config file";
        return 0;
    }

    return 1;
}

sub cleanup {
    my ($self) = @_;

    my $directory = $self->directory;

    # remove test directories
    rmtree($directory);

    # remove test database
    eval "use Test::Database";
    return  if($@);

    my $td1 = Test::Database->handle( 'mysql' );
    return  unless($td1);

    $td1->{driver}->drop_database($td1->name);
}

sub labyrinth {
    my ($self,@plugins) = @_;
    $self->{error} = '';

    my $config = $self->config;

    eval {
        # configure labyrinth instance
        $self->{labyrinth} = Labyrinth->new;

        Labyrinth::Variables::init();   # initial standard variable values

        UnPublish();                    # Start a fresh slate
        LoadSettings($config);          # Load All Global Settings

        DBConnect();

        load_plugins( @plugins );
    };

    return 1    unless($@);
    $self->{error} = "Failed to load Labyrinth: $@";
    return 0;
}

sub action {
    my ($self,$action) = @_;
    $self->{error} = '';

    eval {
        # run plugin action
        $self->{labyrinth}->action($action);
    };

    return 1    unless($@);
    $self->{error} = "Failed to run action: $action: $@";
    return 0;
}

sub refresh {
    my ($self,$plugins,$vars,$params) = @_;

    $self->labyrinth(@$plugins);
    $self->set_vars( %$vars )       if($vars);
    $self->set_params( %$params )   if($params);
}

sub clear {
    my ($self) = @_;

    %tvars      = ();
    %cgiparams  = ();
}

sub vars {
    my ($self) = @_;
    return \%tvars;
}

sub set_vars {
    my ($self,%hash) = @_;
    for my $name (keys %hash) {
        $tvars{$name} = $hash{$name}
    }
}

sub params {
    my ($self) = @_;
    return \%cgiparams;
}

sub set_params {
    my ($self,%hash) = @_;
    for my $name (keys %hash) {
        $cgiparams{$name} = $hash{$name}
    }
}

sub error {
    my ($self) = @_;
    return $self->{error};
}

#----------------------------------------------------------------------------
# Internal Functions

sub copy_files {
    my ($self,$source_dir,$target_dir) = @_;

    unless($source_dir) {
        $self->{error} = "no source directory given";
        return 0;
    }
    unless($target_dir) {
        $self->{error} = "no target directory given";
        return 0;
    }
    unless(-f $source_dir || -d $source_dir) {
        $self->{error} = "failed to find source directory/file: $source_dir";
        return 0;
    }

    my @dirs = ($source_dir);
    while(@dirs) {
        my $dir = shift @dirs;

        my @files = glob("$dir/*");

        for my $filename (@files) {
            my $source = $filename;
            if(-f $source) {
                my $target = $filename;
                $target =~ s/^$source_dir/$target_dir/;
                next    if(-f $target);

                mkpath( dirname($target) );
                if(-d dirname($target)) {
                    copy( $source, $target );
                } else {
                    $self->{error} = "failed to created directory: " . dirname($target);
                    return 0;
                }
            } elsif(-d $source) {
                push @dirs, $source;

            } else {
                $self->{error} = "failed to to find source: $source";
                return 0;
            }
        }
    }

    return 1;
}

sub create_config {
    my ($self,$db_config) = @_;
    my $admin = 'barbie@cpan.org';

    my $config      = $self->config;
    my $directory   = $self->directory;

    # main config
    unlink $config if -f $config;

    my $dbcfg1 = join("\n", map { "$_=$db_config->{$_}" } grep { $db_config->{$_}} qw(driver database dbfile dbhost dbport dbuser dbpass) );

    my $fh = IO::File->new($config,'w+') or return 0;
    print $fh <<PRINT;
[PROJECT]
icode=testsite
iname=Test Site
administrator=$admin
mailhost=
cookiename=session
timeout=3600
autoguest=1
copyright=2002-2014 Barbie
lastpagereturn=0
minpasslen=6
maxpasslen=20

evalperl=1

[INTERNAL]
phrasebook=$directory/cgi-bin/config/phrasebook.ini
logfile=$directory/html/cache/audit.log
loglevel=4
logclear=1

[HTTP]
webpath=
cgipath=/cgi-bin
realm=public
basedir=$directory
webdir=$directory/html
cgidir=$directory/cgi-bin

requests=$directory/cgi-bin/config/requests

; database configuration

[DATABASE]
$dbcfg1

[CMS]
htmltags=+img
maxpicwidth=500
randpicwidth=400
blank=images/blank.png

testing=0

PRINT

    $fh->close;
    return 1;
}

# this is primitive, but works :)

sub create_mysql_databases {
    my ($db1,@files) = @_;

    my (@statements);
    my $sql = '';

    for my $file (@files) {
#print STDERR "# file=$file\n";
        my $fh = IO::File->new($file,'r') or next;
        while(<$fh>) {
            next    if(/^--/);  # ignore comment lines
            s/;\s+--.*/;/;      # remove end of line comments
            s/\s+$//;           # remove trailing spaces
            next    unless($_);

#print STDERR "# line=$_\n";
            $sql .= ' ' . $_;
#print STDERR "# sql=$sql\n";
#exit;
            if($sql =~ /;$/) {
                $sql =~ s/;$//;
                push @statements, $sql;
                $sql = '';
            }
        }
        $fh->close;
    }

#print STDERR "# statements=".join("\n# ",@statements)."\n";
    dosql($db1,\@statements);
}

sub dosql {
    my ($db,$sql) = @_;

    for(@$sql) {
        #diag "SQL: [$db] $_";
        eval { $db->dbh->do($_); };
        if($@) {
            diag $@;
            return 1;
        }
    }

    return 0;
}

1;

__END__

=head1 METHODS

=head2 The Constructor

=over

=item new( %options )

Harness object constructor.

Defines a default config file and directory, unless otherwise provided.

Options available are:

  config    => $config
  directory => $directory

=back

=head2 Public Methods

=over

=item prep( @sql )

Prepares the environment. Copies files from the current vhost directory, 
creates a database, and runs the necessary SQL to create the required tables
and add the appropriate data. Saves the configuration settings to the
designated config file.

=item labyrinth( @plugins )

Loads an instance of Labyrinth. Will also pre-load the list of given plugins.

=item action( $action )

Runs the named plugin action.

=item refresh( \@plugins, $vars_hash, $params_hash )

Refreshes the current instance by reloading the Labyrinth instances, together
with the name plugins, and adding the variables and parameters to the current
internal hashes.

Essentially a short cut to calling labyrinth(), set_vars() and set_params()
separately.

=item cleanup

Clean up the instance, removes the current directory and deletes the test
database.

=back

=head2 Internal Variables

=over

=item clear

Clear the internal variables and parameters hashes.

=item params

returns the current parameters hash.

=item set_params( %hash )

Adds the given parameters to the current paraments hash.

=item vars

returns the current variables hash.

=item set_vars( %hash )

Adds the given variables to the current variables hash.

=item error

Returns the last error recorded.

=back

=head2 Internal Methods

=over

=item copy_files( $source, $target )

Copies files between the source and target directories.

=item create_config( $db_config )

Creates a configuration file.

=item create_mysql_databases( @files )

Creates the test database. The @files array, lists the SQL files containing
SQL statements to run on the test database.

=item dosql

Runs an SQL command.

=back

=head1 SEE ALSO

L<Labyrinth>

L<http://labyrinth.missbarbell.co.uk>

=head1 AUTHOR

Barbie, <barbie@missbarbell.co.uk> for
Miss Barbell Productions, L<http://www.missbarbell.co.uk/>

=head1 COPYRIGHT & LICENSE

  Copyright (C) 2014 Barbie for Miss Barbell Productions
  All Rights Reserved.

  This module is free software; you can redistribute it and/or
  modify it under the Artistic License 2.0.

=cut
