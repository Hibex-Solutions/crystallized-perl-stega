package Stega::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -strict;

use Stega::Repository::Pg::Ticket;

sub index {
    my $c    = shift;
    my $user = $c->stash('current_user');

    my $tickets = Stega::Repository::Pg::Ticket->new(db => $c->pg->db)
        ->list_for_dashboard(role => $user->{role}, user_id => $user->{id});

    $c->render(template => 'dashboard/index', tickets => $tickets);
}

1;
