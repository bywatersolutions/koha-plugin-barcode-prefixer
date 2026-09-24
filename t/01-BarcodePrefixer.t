#!/usr/bin/perl

use Modern::Perl;

BEGIN {
    unshift( @INC, '/var/lib/koha/kohadev/plugins' );
    unshift( @INC, '/kohadevbox/koha' );
    unshift( @INC, '/kohadevbox/koha/t/lib' );
}

use Test::NoWarnings;
use Test::More tests => 6;

# A dev install has the literal placeholder "{VERSION}" as its version, which
# makes every version compare in Koha::Plugins::Base warn. Koha::Plugins loads
# enabled plugins at compile time, so filter that noise before the Koha
# modules load or Test::NoWarnings fails on it.
BEGIN {
    my $previous_warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub {
        return if $_[0] =~ m/Argument "\{VERSION\}" isn't numeric/;
        $previous_warn ? $previous_warn->(@_) : warn @_;
    };
}

use CGI;
use YAML;

use Koha::Database;
use Koha::Patron;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer->new;

# The hooks read the configuration from the database on every call
sub set_config {
    my ($data) = @_;

    $plugin->store_data( { yaml_config => YAML::Dump($data) } );

    return $data;
}

# Run the code as if memberentry.pl had just parsed this posted form. CGI.pm caches
# the first form it parses in the process, so that cache is cleared first.
sub with_posted_form {
    my ( $body, $code ) = @_;

    local $ENV{SCRIPT_NAME}    = '/cgi-bin/koha/members/memberentry.pl';
    local $ENV{REQUEST_METHOD} = 'POST';
    local $ENV{CONTENT_TYPE}   = 'application/x-www-form-urlencoded';
    local $ENV{CONTENT_LENGTH} = length $body;
    local *STDIN;
    open STDIN, '<', \$body or die $!;
    CGI::initialize_globals();

    return $code->();
}

subtest 'next_patron_cardnumber() tests' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;

    my $data = {
        patron_barcode_length => 12,
        libraries             => {
            $library_a => { patron_prefix => 9871 },
            $library_b => { patron_prefix => 9872, patron_barcode_length => 10 },
        },
    };

    is( $plugin->next_patron_cardnumber( $data, $library_a ), '987100000001', 'First cardnumber for a library' );

    $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => '987100000005' } } );
    is( $plugin->next_patron_cardnumber( $data, $library_a ), '987100000006', 'Next cardnumber after the highest in use' );

    $builder->build_object( { class => 'Koha::Patrons', value => { cardnumber => '987100000009' } } );
    is( $plugin->next_patron_cardnumber( $data, $library_a ), '987100000010', 'Padding shrinks when the number grows a digit' );

    is( $plugin->next_patron_cardnumber( $data, $library_b ), '9872000001', 'Library level patron_barcode_length overrides the global one' );

    my $cardnumber = $plugin->next_patron_cardnumber( { patron_barcode_length => 12 }, $library_a );
    is( $cardnumber, undef, 'No cardnumber for a library without a patron_prefix' );

    $cardnumber = $plugin->next_patron_cardnumber( { libraries => { $library_a => { patron_prefix => 9871 } } }, $library_a );
    is( $cardnumber, undef, 'No cardnumber without a patron_barcode_length' );

    $schema->storage->txn_rollback;
};

subtest 'patron_prefix_branchcode() tests' => sub {
    plan tests => 5;

    $schema->storage->txn_begin;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;

    t::lib::Mocks::mock_userenv( { branchcode => $library_a } );

    my $login = {};
    my $form  = { patron_prefix_library => 'form' };

    {
        local $ENV{SCRIPT_NAME} = '/cgi-bin/koha/members/memberentry.pl';
        is( $plugin->patron_prefix_branchcode($login), $library_a, 'Logged in library by default' );
    }

    {
        local $ENV{SCRIPT_NAME} = '/cgi-bin/koha/circ/circulation.pl';
        is( $plugin->patron_prefix_branchcode($form), $library_a, 'Logged in library outside of the patron entry form' );
    }

    my $branchcode = with_posted_form( "branchcode=$library_b&surname=x", sub { $plugin->patron_prefix_branchcode($form) } );
    is( $branchcode, $library_b, 'Library posted from the patron entry form' );

    $branchcode = with_posted_form( "surname=x", sub { $plugin->patron_prefix_branchcode($form) } );
    is( $branchcode, $library_a, 'Logged in library when the form has no library' );

    # The first call leaves STDIN at its end, so the second call only works if the plugin rewinds it
    $branchcode = with_posted_form(
        "branchcode=$library_b&surname=x",
        sub {
            $plugin->patron_prefix_branchcode($form);
            CGI::initialize_globals();
            $plugin->patron_prefix_branchcode($form);
        }
    );
    is( $branchcode, $library_b, 'Posted library is read again on a second call' );

    $schema->storage->txn_rollback;
};

subtest 'patron_barcode_transform() tests' => sub {
    plan tests => 9;

    $schema->storage->txn_begin;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;

    t::lib::Mocks::mock_userenv( { branchcode => $library_a } );
    t::lib::Mocks::mock_preference( 'autoMemberNumValue', 0 );

    my $data = set_config(
        {
            patron_barcode_length => 12,
            libraries             => {
                $library_a => { patron_prefix => 9871 },
                $library_b => { patron_prefix => 9872 },
            },
        }
    );

    t::lib::Mocks::mock_preference( 'autoMemberNum', 0 );
    my $barcode;
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, undef, 'Blank cardnumber is left alone when autoMemberNum is off' );

    t::lib::Mocks::mock_preference( 'autoMemberNum', 1 );
    $barcode = undef;
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, '987100000001', 'Blank cardnumber gets the next cardnumber for the logged in library' );

    t::lib::Mocks::mock_preference( 'autoMemberNumValue', undef );
    $barcode = undef;
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, '987100000000', 'Without Bug 34000 the cardnumber before the next one is returned' );
    t::lib::Mocks::mock_preference( 'autoMemberNumValue', 0 );

    set_config( { patron_barcode_length => 12, libraries => { $library_b => { patron_prefix => 9872 } } } );
    $barcode = undef;
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, undef, 'Blank cardnumber is left alone when the logged in library has no prefix' );
    set_config($data);

    $barcode = '12';
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, '987100000012', 'Short cardnumber is prefixed and padded for the logged in library' );

    $barcode = '987100000099';
    $plugin->patron_barcode_transform( \$barcode );
    is( $barcode, '987100000099', 'Full length cardnumber is left alone' );

    set_config( { %$data, patron_prefix_library => 'form' } );

    $barcode = undef;
    with_posted_form( "branchcode=$library_b", sub { $plugin->patron_barcode_transform( \$barcode ) } );
    is( $barcode, '987200000001', 'Blank cardnumber gets the next cardnumber for the library on the form' );

    $barcode = '7';
    with_posted_form( "branchcode=$library_b", sub { $plugin->patron_barcode_transform( \$barcode ) } );
    is( $barcode, '987200000007', 'Short cardnumber is prefixed for the library on the form' );

    set_config($data);

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );
    $plugin->enable;
    my $category = $builder->build_object( { class => 'Koha::Patron::Categories' } );
    my $patron   = Koha::Patron->new(
        {
            surname      => 'Prefixer',
            categorycode => $category->categorycode,
            branchcode   => $library_a,
        }
    )->store;
    is( $patron->cardnumber, '987100000001', 'Koha stores the cardnumber from the plugin as-is' );

    $schema->storage->txn_rollback;
};

subtest 'intranet_js() tests' => sub {
    plan tests => 9;

    $schema->storage->txn_begin;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;

    t::lib::Mocks::mock_userenv( { branchcode => $library_a } );
    t::lib::Mocks::mock_preference( 'autoMemberNum', 1 );

    my $data = set_config(
        {
            patron_barcode_length     => 12,
            prefill_patron_cardnumber => 1,
            libraries                 => { $library_a => { patron_prefix => 9871 } },
        }
    );

    {
        local $ENV{SCRIPT_NAME} = '/cgi-bin/koha/circ/circulation.pl';
        is( $plugin->intranet_js, q{}, 'Nothing outside of the patron entry form' );
    }

    local $ENV{SCRIPT_NAME} = '/cgi-bin/koha/members/memberentry.pl';

    t::lib::Mocks::mock_preference( 'autoMemberNum', 0 );
    is( $plugin->intranet_js, q{}, 'Nothing when autoMemberNum is off' );
    t::lib::Mocks::mock_preference( 'autoMemberNum', 1 );

    set_config( { %$data, prefill_patron_cardnumber => 0 } );
    is( $plugin->intranet_js, q{}, 'Nothing when prefill_patron_cardnumber is off' );

    set_config($data);
    my $js = $plugin->intranet_js;
    like( $js, qr/fill_cardnumber\( "987100000001" \)/, 'Next cardnumber is filled in' );
    unlike( $js, qr/getJSON/, 'No API call when following the logged in library' );

    set_config(
        {
            patron_barcode_length => 12,
            libraries             => { $library_a => { patron_prefix => 9871, prefill_patron_cardnumber => 1 } },
        }
    );
    like( $plugin->intranet_js, qr/fill_cardnumber\( "987100000001" \)/, 'prefill_patron_cardnumber can be set at the library level' );

    set_config( { %$data, patron_prefix_library => 'form' } );
    $js = $plugin->intranet_js;
    like( $js, qr{\$\.getJSON\( "/api/v1/contrib/barcodeprefixer/next_patron_cardnumber"}, 'Cardnumber is fetched for the library on the form' );
    unlike( $js, qr/fill_cardnumber\( "\d/, 'No cardnumber is filled in up front when following the form' );

    set_config( { %$data, libraries => {} } );
    is( $plugin->intranet_js, q{}, 'Nothing when the logged in library has no prefix' );

    $schema->storage->txn_rollback;
};

subtest 'barcode_transform() and item_barcode_transform() tests' => sub {
    plan tests => 10;

    $schema->storage->txn_begin;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;

    t::lib::Mocks::mock_userenv( { branchcode => $library_a } );
    t::lib::Mocks::mock_preference( 'autoMemberNum', 1 );
    t::lib::Mocks::mock_preference( 'autoMemberNumValue', 0 );

    my $data = set_config(
        {
            item_barcode_length   => 14,
            patron_barcode_length => 12,
            libraries             => {
                $library_a => { item_prefix => 9873, patron_prefix => 9871 },
                $library_b => { patron_prefix => 9872 },
            },
        }
    );

    my $barcode = '12';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '98730000000012', 'Short item barcode is prefixed and padded' );

    $barcode = '98730000000099';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '98730000000099', 'Full length item barcode is left alone' );

    $barcode = 'ABC12';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, 'ABC12', 'Non-numeric barcode is left alone by default' );

    set_config( { %$data, always_transform => 1 } );
    $barcode = 'ABC12';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '987300000ABC12', 'Non-numeric barcode is prefixed with always_transform' );

    set_config( { %$data, never_prefix_if => '^9' } );
    $barcode = '912';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '912', 'Barcode matching never_prefix_if is left alone' );

    set_config( { %$data, only_prefix_if => '^1' } );
    $barcode = '912';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '912', 'Barcode not matching only_prefix_if is left alone' );

    set_config(
        {
            %$data,
            libraries => { $library_a => { item_prefix => 9873, prefix_without_padding => 1 } },
        }
    );
    $barcode = '12';
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '987312', 'Barcode is prefixed without padding with prefix_without_padding' );

    set_config($data);
    $barcode = '12';
    with_posted_form( "branchcode=$library_b", sub { $plugin->patron_barcode_transform( \$barcode ) } );
    is( $barcode, '987100000012', 'Library on the form is ignored for patron cardnumbers by default' );

    set_config( { %$data, auto_barcode => 'incremental' } );
    $barcode = undef;
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '98730000000001', 'First item barcode for a library' );

    $builder->build_sample_item( { barcode => '98730000000001' } );
    $barcode = undef;
    $plugin->item_barcode_transform( \$barcode );
    is( $barcode, '98730000000002', 'Next item barcode after the highest in use' );

    $schema->storage->txn_rollback;
};
