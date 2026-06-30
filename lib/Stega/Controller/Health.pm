package Stega::Controller::Health;
use Mojo::Base 'Mojolicious::Controller', -strict;

sub check {
    my $c = shift;

    my $db_ok = eval { $c->pg->db->query('SELECT 1'); 1 } // 0;

    if ($db_ok) {
        return $c->render(json => { status => 'ok' });
    }

    $c->render(
        json   => { status => 'degraded', detail => 'database unavailable' },
        status => 503,
    );
}

1;
