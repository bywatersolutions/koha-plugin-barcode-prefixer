#!/usr/bin/perl

use Modern::Perl;

BEGIN {
    unshift( @INC, '/var/lib/koha/kohadev/plugins' );
    unshift( @INC, '/kohadevbox/koha' );
    unshift( @INC, '/kohadevbox/koha/t/lib' );
}

use Test::NoWarnings;
use Test::More tests => 2;
use Test::Mojo;

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

use YAML;

use Koha::Database;
use Koha::Plugins;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'next_patron_cardnumber() tests' => sub {
    plan tests => 12;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'enable_plugins', 1 );
    t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

    # The plugin must be installed and enabled before the app starts so its
    # routes are merged into the API spec
    Koha::Plugins->new->InstallPlugins( { include => ['Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer'] } );
    my $plugin = Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer->new;
    $plugin->enable;

    my $library_a = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    my $library_b = $builder->build_object( { class => 'Koha::Libraries' } )->branchcode;
    $plugin->store_data(
        {
            yaml_config => YAML::Dump(
                {
                    patron_barcode_length => 12,
                    libraries             => { $library_a => { patron_prefix => 9871 } },
                }
            )
        }
    );

    my $t = Test::Mojo->new('Koha::REST::V1');

    my $password  = 'thePassword123';
    my $librarian = $builder->build_object( { class => 'Koha::Patrons', value => { flags => 2**4 } } );
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    my $unauthorized = $builder->build_object( { class => 'Koha::Patrons', value => { flags => 2**2 } } );
    $unauthorized->set_password( { password => $password, skip_validation => 1 } );
    my $unauthorized_userid = $unauthorized->userid;

    my $path = '/api/v1/contrib/barcodeprefixer/next_patron_cardnumber';

    $t->get_ok("//$userid:$password\@$path?branchcode=$library_a")
      ->status_is(200)
      ->json_is( '/cardnumber', '987100000001' );

    $t->get_ok("//$userid:$password\@$path?branchcode=$library_b")
      ->status_is(200)
      ->json_is( '/cardnumber', undef );

    $t->get_ok("//$userid:$password\@$path")
      ->status_is(400);

    $t->get_ok("$path?branchcode=$library_a")
      ->status_is(401);

    $t->get_ok("//$unauthorized_userid:$password\@$path?branchcode=$library_a")
      ->status_is(403);

    $schema->storage->txn_rollback;
};
