package Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth;

use YAML qw(Load Dump);

our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Scanned Barcode Prefixer',
    author          => 'Kyle M Hall',
    date_authored   => '2020-07-02',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Prefix scanned barcodes',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub patron_barcode_transform {
    my ( $self, $barcode ) = @_;

    if ( $$barcode ) {
        $self->barcode_transform( 'patron', $barcode );
    } elsif (C4::Context->preference("autoMemberNum")) { # fixup_cardnumber, Autogenerate next cardnumber from highest value found in database
        my $branchcode = C4::Context->userenv->{branch};
        return unless $branchcode;

        my $yaml = $self->retrieve_data('yaml_config');
        return $barcode unless $yaml;

        my $data;
        eval { $data = YAML::Load( $yaml ); };
        return unless $data;

        my $barcode_length = $data->{patron_barcode_length};
        return unless $barcode_length;

        my $barcode_prefix = $data->{libraries}->{$branchcode}->{patron_prefix};;
        return unless $barcode_prefix;

        my $max = Koha::Patrons->search(
            {
                -and => [
                    cardnumber => { -regexp => '^-?[0-9]+$' },
                    cardnumber => { -regexp => "^$barcode_prefix" },
                    \[ 'LENGTH(cardnumber) = ?', $barcode_length ],
                ]
            },
            {
                select => \'CAST(cardnumber AS SIGNED)',
                as     => ['cast_cardnumber']
            }
        )->_resultset->get_column('cast_cardnumber')->max;
        $max =~ s/^$barcode_prefix//;
        my $next = $max + 1;

        my $prefix_len  = length( $barcode_prefix );
        my $next_len    = length($next);
        my $padding_len = $barcode_length - $prefix_len - $next_len;
        my $padding     = '0' x $padding_len;

        my $cardnumber = $barcode_prefix . $padding . $next;

        while ( my $patron = Koha::Patrons->find( { cardnumber => $cardnumber } ) )
        {
            $next++;
            $next_len    = length($next);
            $padding_len = $barcode_length - $prefix_len - $next_len;
            $padding     = '0' x $padding_len;
            $cardnumber  = $barcode_prefix . $padding . $next;
        }

        $$barcode = $cardnumber;
    }
}

sub item_barcode_transform {
    my ( $self, $barcode ) = @_;

    if ( defined $$barcode && $$barcode ne q{} ) {
        $self->barcode_transform( 'item', $barcode );
    }
}

sub barcode_transform {
    my ( $self, $type, $barcode_ref ) = @_;

    my $barcode = $$barcode_ref;

    my $branchcode = C4::Context->userenv->{branch};
    return unless $branchcode;

    my $yaml = $self->retrieve_data('yaml_config');
    return $barcode unless $yaml;

    my $data;
    eval { $data = YAML::Load($yaml); };
    return unless $data;

    # Only transform all digit barcodes by default
    return unless $data->{always_transform} || $barcode =~ /^\d*$/;

    my $barcode_length = $data->{ $type . "_barcode_length" };
    return unless $barcode_length;

    if ( length($barcode) < $barcode_length ) {
        my $prefix =
          $data->{libraries}->{$branchcode}->{ $type . "_prefix" };
        my $padding = $barcode_length - length($prefix) - length($barcode);
        $barcode = $prefix . '0' x $padding . $barcode if ( $padding >= 0 );

        $$barcode_ref = $barcode;
    }
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        my $yaml = $self->retrieve_data('yaml_config');
        my $data;
        eval { $data = YAML::Load( $yaml ); };

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            yaml_config => $self->retrieve_data('yaml_config'),
            yaml_error => $yaml && !$data,
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                yaml_config => $cgi->param('yaml_config'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    my $yaml = $self->retrieve_data('yaml_config');
    return 1 if $yaml;

    my $itembarcodelength = C4::Context->preference('itembarcodelength');
    my $patronbarcodelength = C4::Context->preference('patronbarcodelength');

    my $data = {
        item_barcode_length => $itembarcodelength,
        patron_barcode_length => $patronbarcodelength,
    };

    require Koha::Libraries;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT * FROM branches");
    $sth->execute();
    while ( my $l = $sth->fetchrow_hashref ) {
        $data->{libraries}->{$l->{branchcode}}->{item_prefix} = $l->{itembarcodeprefix};
        $data->{libraries}->{$l->{branchcode}}->{patron_prefix} = $l->{patronbarcodeprefix};
    }

    $self->store_data(
        {
            yaml_config => Dump( $data ),
        }
    );

    require Koha::Config::SysPrefs;
    $itembarcodelength = Koha::Config::SysPrefs->find('itembarcodelength');
    $itembarcodelength->delete() if $itembarcodelength;
    $patronbarcodelength = Koha::Config::SysPrefs->find('patronbarcodelength');
    $patronbarcodelength->delete() if $patronbarcodelength;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

1;
