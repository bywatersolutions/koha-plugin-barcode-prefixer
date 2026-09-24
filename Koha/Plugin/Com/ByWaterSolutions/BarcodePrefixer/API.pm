package Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer::API;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';
use Try::Tiny;
use YAML;

use Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer;

=head1 API

=head3 next_patron_cardnumber

Returns the next available patron cardnumber for the given library

=cut

sub next_patron_cardnumber {
    my $c = shift->openapi->valid_input or return;

    return try {
        my $plugin     = Koha::Plugin::Com::ByWaterSolutions::BarcodePrefixer->new;
        my $branchcode = $c->param('branchcode');

        my $data       = YAML::Load( $plugin->retrieve_data('yaml_config') );
        my $cardnumber = $plugin->next_patron_cardnumber( $data, $branchcode );

        return $c->render( status => 200, openapi => { cardnumber => $cardnumber } );
    } catch {
        $c->unhandled_exception($_);
    };
}

1;
